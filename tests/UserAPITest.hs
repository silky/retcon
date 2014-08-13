
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PolyKinds             #-}

module Main where

import Test.Hspec

import Control.Monad.IO.Class
import Data.Proxy
import GHC.TypeLits
import System.Directory
import System.Exit
import System.FilePath

import Retcon.Config
import Retcon.DataSource
import Retcon.DataSource.JsonDirectory
import Retcon.Handler

import TestHelpers

-- | Path to the "customer:data" JSON files.
customerDataPath :: FilePath
customerDataPath = joinPath ["tests", "data"]

-- | Path to the "customer:test-results" JSON files.
customerTestResultsPath :: FilePath
customerTestResultsPath = joinPath ["tests", "test-results"]

instance RetconEntity "customer" where
    entitySources _ = [
        SomeDataSource (Proxy :: Proxy "data"),
        SomeDataSource (Proxy :: Proxy "test-results")
        ]

instance RetconDataSource "customer" "data" where
    getDocument key = liftIO $ do
        res <- getJsonDirDocument customerDataPath key
        either (error . show) return res

    setDocument doc key = liftIO $ do
        res <- setJsonDirDocument customerDataPath doc key
        either (error . show) (\x ->
            case x of
                Nothing -> error "No key"
                Just y  -> return y) res

    deleteDocument key = liftIO $ do
        res <- deleteJsonDirDocument customerDataPath key
        either (error . show) return res

instance RetconDataSource "customer" "test-results" where
    getDocument key = liftIO $ do
        res <- getJsonDirDocument customerTestResultsPath key
        either (error . show) return res

    setDocument doc key = liftIO $ do
        res <- setJsonDirDocument customerTestResultsPath doc key
        either (error . show) (\x ->
            case x of
                Nothing -> error "No key"
                Just y  -> return y) res

    deleteDocument key = liftIO $ do
        res <- deleteJsonDirDocument customerTestResultsPath key
        either (error . show) return res

-- | test suite
suite :: Spec
suite = do
    describe "JSON directory marshalling" $ do
        it "can load 01-diff-source" $ do
            res <- runDataSourceAction $ do
                getDocument (ForeignKey "01-diff-source" :: ForeignKey "customer" "data")
            pass

        it "can load 01-diff-target" $ do
            res <- runDataSourceAction $ do
                getDocument (ForeignKey "01-diff-target" :: ForeignKey "customer" "data")
            pass

        it "can write 01-diff-source to another source with that key" $ do
            runDataSourceAction $ do
                doc3 <- getDocument (ForeignKey "01-diff-source" :: ForeignKey "customer" "data")
                test3Key <- setDocument doc3 (Just (ForeignKey "01-diff-source" :: ForeignKey "customer" "test-results"))
                return ()
            pass

        it "can write 01-diff-source to another source with new key" $ do
            res <- runDataSourceAction $ do
                doc4 <- getDocument (ForeignKey "01-diff-source" :: ForeignKey "customer" "data")
                setDocument doc4 (Nothing :: Maybe (ForeignKey "customer" "test-results"))
            pass

        it "can delete 01-diff-source from the test source" $ do
            res <- runDataSourceAction $ do
                getDocument (ForeignKey "01-diff-source" :: ForeignKey "customer" "test-results")
                deleteDocument (ForeignKey "01-diff-source" :: ForeignKey "customer" "test-results")
            pass

-- | This test is mainly to make sure that the types line up in the
-- instances above.
main :: IO ()
main = do
    createDirectoryIfMissing True customerTestResultsPath
    hspec suite
  where
    cfg = RetconConfig [ SomeEntity (Proxy :: Proxy "customer") ]
