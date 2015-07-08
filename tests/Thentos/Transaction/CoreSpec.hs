{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE InstanceSigs          #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE UndecidableInstances  #-}

module Thentos.Transaction.CoreSpec where

import Control.Lens ((%~), (%%~), (^.))
import Test.Hspec (Spec, describe, it, shouldBe, hspec, before, after)

import Thentos.Types
import Thentos.Transaction (AllUserIds(..))

import Data.Acid (openLocalStateFrom)
import Data.Acid.Advanced (query')

import Test.Arbitrary ()
import Test.Core
import Test.CustomDB
import Test.Types


tests :: IO ()
tests = hspec spec

spec :: Spec
spec = describe "Thentos.Transaction.Core" $ do
    spec_polyQU
    spec_useCustomDB

spec_polyQU :: Spec
spec_polyQU = describe "asDB, polyQuery, polyUpdate" $ do
    it "works" $ do
        let f :: DB -> DB
            f = id

            g :: (db `Extends` DB) => db -> db
            g = focus %~ f

            h :: DB -> (String, DB)
            h db = (show db, db)

            i :: (db `Extends` DB) => db -> (String, db)
            i = focus %%~ h

            test0 :: (Eq db, Show db, db `Extends` DB) => db -> IO ()
            test0 db = do
                db `shouldBe` g db
                db `shouldBe` snd (i db)

        test0 $ emptyDB
        test0 $ CustomDB emptyDB 3

        let db = CustomDB emptyDB 3 in case i db of
              (prn', CustomDB db' x) -> do
                  prn' `shouldBe` show db'
                  db' `shouldBe` emptyDB
                  x `shouldBe` 3

spec_useCustomDB :: Spec
spec_useCustomDB = describe "custom db" . before setupBare . after teardownBare $ do
    it "works" $ \ (TS tcfg) -> do
        st <- openLocalStateFrom (tcfg ^. tcfgDbPath) (CustomDB emptyDB 3)
        u <- query' st AllUserIds
        u `shouldBe` Right []

        theInt <- query' st GetTheInt
        theInt `shouldBe` Right 3
        return ()
