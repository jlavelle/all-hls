#! /usr/bin/env nix-shell
#! nix-shell --keep GITHUB_TOKEN --keep NIX_SSL_CERT_FILE
#! nix-shell -p "haskellPackages.ghcWithPackages (p: [ p.text p.bytestring p.github p.vector p.regex-tdfa p.aeson p.aeson-pretty p.cryptohash-sha256 p.http-client p.http-client-tls p.base16 p.async ])"
#! nix-shell -i runhaskell

{-# LANGUAGE
    OverloadedStrings
  , QuasiQuotes
  , TupleSections
  , DeriveGeneric
  , DerivingStrategies
  , DeriveAnyClass
  , GeneralizedNewtypeDeriving
  , PackageImports
  , BangPatterns
#-}

import Prelude hiding ( writeFile, putStrLn )

import GitHub
import System.Environment ( getEnv, getArgs )

import Control.Arrow ( (&&&) )

import Control.Category ( (<<<), (>>>) )

import Data.List ( find )
import Data.Maybe ( catMaybes )

import Data.Text ( Text, pack, unpack )
import Data.Text.IO ( putStrLn )

import Data.Map ( Map )
import qualified Data.Map as M

import Data.Vector ( Vector )
import qualified Data.Vector as V

import Data.Maybe ( maybeToList )

import Text.Regex.TDFA

import Data.Aeson ( ToJSON(..), ToJSONKey(..) )
import qualified Data.Aeson as J
import qualified Data.Aeson.Encode.Pretty as J

import GHC.Generics (Generic)

import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy as LBS

import qualified Crypto.Hash.SHA256 as H

import Control.Applicative ( liftA2 )

import Data.Functor ((<&>))

import qualified Network.HTTP.Client.TLS as TLS
import Network.HTTP.Client ( parseUrlThrow, withResponse, responseBody )

import "base16" Data.ByteString.Base16 ( encodeBase16 )

import Control.Concurrent.Async ( Concurrently(..), runConcurrently )

data Platform = Linux | MacOS | Windows
  deriving stock    (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON)

instance ToJSONKey Platform
  where
  toJSONKey = J.genericToJSONKey J.defaultJSONKeyOptions

type Version = Text
type Hash = Text

data Ref = Ref { url :: URL, hash :: Hash }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON)

data HLSRelease = HLSRelease { wrapper :: Ref, ghcs :: Map Version Ref }
  deriving stock    (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON)

type Result = Map Version (Map Platform HLSRelease)

main :: IO ()
main = do
  token <- getEnv "GITHUB_TOKEN"
  path <- getArgs <&> \xs -> if null xs then "./sources.json" else head xs
  Right releases <- github (OAuth $ BS.pack token) $ releasesR "haskell" "haskell-language-server" 10
  result <- hlsReleases $ V.toList releases
  LBS.writeFile path $ J.encodePretty' (J.defConfig { J.confIndent = J.Spaces 2 }) $ result

  where

  hlsReleases :: [Release] -> IO Result
  hlsReleases
    =   fmap (releaseTagName &&& (V.toList . releaseAssets))
    >>> M.fromList
    >>> traverse extractBins

  extractBins :: [ReleaseAsset] -> IO (Map Platform HLSRelease)
  extractBins assets = fmap M.fromList $ foldMap (fmap maybeToList . flip extractRefs assets) $ [Linux, MacOS, Windows]

  extractRefs :: Platform -> [ReleaseAsset] -> IO (Maybe (Platform, HLSRelease))
  extractRefs p assets = fmap (fmap (p, )) $ liftA2 (liftA2 HLSRelease) hlws (fmap pure hls)
    where
    platformName :: Platform -> Text
    platformName Linux = "Linux"
    platformName MacOS = "macOS"
    platformName Windows = "Windows"

    downloadAndHash :: URL -> IO Hash
    downloadAndHash (URL url) = encodeBase16 <$> do
      manager <- TLS.getGlobalManager
      request <- parseUrlThrow $ unpack url
      withResponse request manager handleResponse
      where
        handleResponse r = loop H.init
          where
            loop !ctx = do
              chunk <- responseBody r
              if BS.null chunk
                then pure $ H.finalize ctx
                else loop $ H.update ctx chunk

    refOfAsset :: ReleaseAsset -> IO Ref
    refOfAsset asset = Ref url <$> downloadAndHash url
      where
      url = URL $ releaseAssetBrowserDownloadUrl $ asset

    hlwsName :: Text
    hlwsName = "haskell-language-server-wrapper-" <> platformName p <> ".gz"

    hlws :: IO (Maybe Ref)
    hlws = traverse refOfAsset $ find ((== hlwsName) . releaseAssetName) assets

    hlsName :: Text
    hlsName = "haskell-language-server-" <> platformName p <> "-([0-9]+\\.[0-9]+\\.[0-9]+)\\.gz"

    hls :: IO (Map Version Ref)
    hls = fmap (M.fromList . catMaybes) $ runConcurrently $ traverse (Concurrently . parseHLS) assets

    parseHLS :: ReleaseAsset -> IO (Maybe (Version, Ref))
    parseHLS asset = traverse (\v -> (v,) <$> refOfAsset asset) maybeGhc
      where
      maybeGhc :: Maybe Version
      maybeGhc = do
        AllTextSubmatches (_:ghc:_) <- releaseAssetName asset =~~ hlsName
        pure ghc
