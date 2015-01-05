{-# LANGUAGE TypeFamilies                             #-}
{-# LANGUAGE ExistentialQuantification                #-}
{-# LANGUAGE FlexibleContexts                         #-}
{-# LANGUAGE FlexibleInstances                        #-}
{-# LANGUAGE GADTs                                    #-}
{-# LANGUAGE InstanceSigs                             #-}
{-# LANGUAGE MultiParamTypeClasses                    #-}
{-# LANGUAGE OverloadedStrings                        #-}
{-# LANGUAGE RankNTypes                               #-}
{-# LANGUAGE ScopedTypeVariables                      #-}
{-# LANGUAGE TupleSections                            #-}
{-# LANGUAGE TypeSynonymInstances                     #-}
{-# LANGUAGE ViewPatterns                             #-}

{-# OPTIONS -fno-warn-unused-imports -fwarn-incomplete-patterns #-}

module Main
where

import Control.Applicative ((<$>))
import Control.Exception (SomeException, throw, catch)
import Data.Acid (AcidState, openLocalStateFrom, query, createCheckpoint, closeAcidState)
import Data.Data (Proxy(Proxy))
import Data.Map (Map)
import Data.Maybe (fromMaybe)
import Data.String.Conversions (cs, (<>))
import Network.Wai.Handler.Warp (run)
import Safe (readMay)
import Servant.Server (serve)
import System.Environment (getArgs)

import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Encode.Pretty as Aeson
import qualified Data.Map as Map

import Servant.Docs (docs, markdown)

import Types
import DB
import Api


-- * main

main :: IO ()
main =
  do
    args <- getArgs
    putStr "setting up acid-state..."
    st :: AcidState DB <- openLocalStateFrom ".acid-state/" emptyDB
    putStrLn " [ok]"

    let switch ["-s"] = do
            putStrLn "database contents:"
            putStrLn "Users:"
            query st AllUsers >>= mapM_ (putStrLn . cs . Aeson.encodePretty)
            putStrLn "Services:"
            query st AllServices >>= mapM_ (putStrLn . cs . Aeson.encodePretty)
        switch ["-a"] = do
            putStrLn "adding user from stdin to database:"
            Just (user :: User) <- Aeson.decode . cs <$> getContents
            update_ st $ AddUser user
        switch ["-a2"] = do
            putStrLn "adding dummy user to database:"
            update_ st . AddUser $ User "dummy" "dummy" "dummy" [] Nothing
        switch ["-r"] = switch ["-r", ""]
        switch ["-r", fromMaybe 8001 . readMay -> port] = do
            putStrLn $ "running rest api on localhost:" <> show port <> ".  press ^C to abort."
            createCheckpointLoop st 16000 Nothing
            run port $ serve (Proxy :: Proxy App) (app st)
        switch ["--docs"] = do
            let api = docs (Proxy :: Proxy App)
            putStrLn $ markdown api
        switch _ = error $ "bad arguments: " <> show args

        finalize = do
          putStr "creating checkpoint and shutting down acid-state..."
          createCheckpoint st
          closeAcidState st
          putStrLn " [ok]"

    catch (switch args) (\ (e :: SomeException) -> finalize >> throw e)
    finalize


-- curl -H "Content-Type: application/json" -X PUT -d '{"userGroups":[],"userPassword":"dummy","userName":"dummy","userID":3,"userEmail":"dummy"}' -v http://localhost:8001/v0.0.1/user/id/3
-- curl -H "Content-Type: application/json" -X POST -d '{"userGroups":[],"userPassword":"dummy","userName":"dummy","userEmail":"dummy"}' -v http://localhost:8001/v0.0.1/user
