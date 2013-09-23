{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE QuasiQuotes #-}

module Main where

import Control.Monad
import Control.Monad.IO.Class
import Control.Concurrent.STM
import Data.Aeson (ToJSON, (.=))
import qualified Data.Aeson as A
import qualified Data.Aeson.Generic  -- for aesonQQ
import qualified Data.Aeson.Types    -- for aesonQQ
import Data.Aeson.QQ (aesonQQ)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IntMap
import Data.Maybe
import Data.Monoid
import Data.Text (Text)
import qualified Data.Text  -- for aesonQQ
import Data.Word
import GHC.Conc.Sync (unsafeIOToSTM)
import Network.HTTP.Types
import System.Random
import Web.Welshy

data DB = DB
    { dbLists :: TVar (IntMap (TVar List)) }

newDB :: IO DB
newDB = do
    dbLists <- newTVarIO IntMap.empty
    return DB {..}

type ListId = Int

data List = List
    { listId :: ListId
    , listItems :: IntMap Item
    }

instance ToJSON List where
    toJSON o = A.object $ [ "list_id" .= listId o
                          , "items" .= IntMap.elems (listItems o) ]

type ItemId = Int

data Item = Item
    { itemId :: ItemId
    , itemText :: Text
    , itemDone :: Bool
    --, itemCreatedAt :: UTCTime  -- for ordering
    --, itemModifiedAt :: UTCTime
    }

instance ToJSON Item where
    toJSON o = A.object $ [ "item_id" .= itemId o
                          , "text" .= itemText o
                          , "done" .= itemDone o ]

updateItem :: Maybe Text -> Maybe Bool -> Item -> Item
updateItem text done item = item { itemText = fromMaybe (itemText item) text
                                 , itemDone = fromMaybe (itemDone item) done }

main = do
    DB {..} <- newDB

    welshy 3000 $ do

        post "/lists" $ do
            listId <- liftIO $ atomically $ do
                listId <- unsafeIOToSTM randomIO
                lists <- readTVar dbLists
                check $ IntMap.notMember listId lists
                let listItems = IntMap.empty
                listVar <- newTVar $ List {..}
                modifyTVar' dbLists $ IntMap.insert listId listVar
                return listId
            header hLocation $ listLocation listId
            json [aesonQQ| { list_id: <|listId|> } |]

        get "/lists/:list_id" $ do
            listId <- capture "list_id"
            list <- join $ liftIO $ atomically $ do
                lists <- readTVar dbLists
                case IntMap.lookup listId lists of
                    Just listVar -> do
                        list <- readTVar listVar
                        return $ return list
                    Nothing -> return $ halt (status notFound404)
            json list

        delete "/lists/:list_id" $ do
            listId <- capture "list_id"
            liftIO $ atomically $ do
                modifyTVar' dbLists $ IntMap.delete listId
            status noContent204

        post "/lists/:list_id/items" $ do
            listId <- capture "list_id"
            itemText <- jsonParam "text"
            item <- join $ liftIO $ atomically $ do
                lists <- readTVar dbLists
                case IntMap.lookup listId lists of
                    Nothing -> return $ halt (status notFound404)
                    Just listVar -> do
                        list <- readTVar listVar
                        itemId <- unsafeIOToSTM randomIO
                        check $ IntMap.notMember itemId (listItems list)
                        let item = Item { itemDone = False, .. }
                            items' = IntMap.insert itemId item (listItems list)
                            list' = list { listItems = items' }
                        writeTVar listVar list'
                        return $ return item
            header hLocation $ itemLocation listId (itemId item)
            json item

        patch "/lists/:list_id/items/:item_id" $ do
            listId <- capture "list_id"
            itemId <- capture "item_id"
            itemText' <- maybeJsonParam "text"
            itemDone' <- maybeJsonParam "done"
            item' <- join $ liftIO $ atomically $ do
                lists <- readTVar dbLists
                case IntMap.lookup listId lists of
                    Nothing -> return $ halt (status notFound404)
                    Just listVar -> do
                        list <- readTVar listVar
                        case IntMap.lookup itemId (listItems list) of
                            Nothing -> return $ halt (status notFound404)
                            Just item -> do
                                let item' = updateItem itemText' itemDone' item
                                    items' = IntMap.insert itemId item' (listItems list)
                                    list' = list { listItems = items' }
                                writeTVar listVar list'
                                return $ return item'
            json item'

        delete "/lists/:list_id/items/:item_id" $ do
            listId <- capture "list_id"
            itemId <- capture "item_id"
            join $ liftIO $ atomically $ do
                lists <- readTVar dbLists
                case IntMap.lookup listId lists of
                    Nothing -> return $ halt (status notFound404)
                    Just listVar -> do
                        list <- readTVar listVar
                        let items' = IntMap.delete itemId (listItems list)
                            list' = list { listItems = items' }
                        writeTVar listVar list'
                        return $ return ()
            status noContent204


listLocation :: ListId -> ByteString
listLocation listId = mconcat [ "/lists/", C.pack (show listId) ]

itemLocation :: ListId -> ItemId -> ByteString
itemLocation listId itemId = mconcat [ "/lists/", C.pack (show listId)
                                     , "/items/", C.pack (show itemId) ]