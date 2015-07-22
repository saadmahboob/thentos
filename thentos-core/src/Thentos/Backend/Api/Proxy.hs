{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE InstanceSigs               #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE TypeSynonymInstances       #-}
{-# LANGUAGE UndecidableInstances       #-}

module Thentos.Backend.Api.Proxy where

import Control.Applicative ((<$>))
import Control.Lens ((^.))
import Control.Monad.Except (throwError)
import Data.Configifier (Tagged(Tagged), (>>.))
import Data.Monoid ((<>))
import Data.Proxy (Proxy(Proxy))
import Data.String.Conversions (cs)
import Network.HTTP.ReverseProxy
import Servant.API (Raw)
import Servant.Server.Internal.ServantErr (responseServantErr)
import Servant.Server (Server, HasServer(..))
import System.Log.Logger (Priority(DEBUG))

import qualified Data.ByteString.Char8 as BSC
import qualified Data.Map as Map
import qualified Data.Text as ST
import qualified Network.HTTP.Client as C
import qualified Network.HTTP.Types.Header as T
import qualified Network.Wai as S

import Thentos.Action
import Thentos.Action.Core
import Thentos.Backend.Core
import Thentos.Config
import Thentos.Types


data ServiceProxy

instance HasServer ServiceProxy where
    type ServerT ServiceProxy m = S.Application
    route Proxy = route (Proxy :: Proxy Raw)

serviceProxy :: (db `Ex` DB, ThentosErrorToServantErr db)
      => C.Manager -> RenderHeaderFun -> ActionState db -> Server ServiceProxy
serviceProxy manager renderHeaderFun state
    = waiProxyTo (reverseProxyHandler renderHeaderFun state)
                 defaultOnExc
                 manager

-- | Proxy or respond based on request headers.
reverseProxyHandler :: (db `Ex` DB, ThentosErrorToServantErr db)
      => RenderHeaderFun -> ActionState db -> S.Request -> IO WaiProxyResponse
reverseProxyHandler renderHeaderFun state req = do
    eRqMod <- runActionE state $ getRqMod renderHeaderFun req
    case eRqMod of
        Right (RqMod uri headers) -> do
          let proxyDest = ProxyDest { pdHost = cs $ proxyHost uri
                                    , pdPort = proxyPort uri }

          let pReq = prepareReq renderHeaderFun headers (proxyPath uri) req
          return $ WPRModifiedRequest pReq proxyDest
        Left e -> WPRResponse . responseServantErr <$> actionErrorToServantErr e

prepareReq :: RenderHeaderFun -> T.RequestHeaders -> BSC.ByteString -> S.Request -> S.Request
prepareReq renderHeaderFun proxyHdrs pathPrefix req
    = req { S.requestHeaders = proxyHdrs <> newHdrs
          , S.rawPathInfo = newPath
          }
    where
        newHdrs = clearCustomHeaders renderHeaderFun (S.requestHeaders req)
        dropLeading = BSC.dropWhile (== '/')
        pathPrefix' = BSC.reverse . dropLeading $ BSC.reverse pathPrefix
        newPath = BSC.concat [ pathPrefix', "/", dropLeading $ S.rawPathInfo req]

-- | Request modifier that contains all information that is needed to
-- alter and forward an incoming request.
data RqMod = RqMod ProxyUri T.RequestHeaders
  deriving (Eq, Show)

-- | Create request modifier with custom headers to add to it and the target URL of the
-- proxied app to forward it to.
--
-- If the request contains a @X-Thentos-Service@ header, we find the proxied app based on
-- this header -- an error is thrown if the "proxies" section of the config doesn't match.
-- Otherwise, the default proxied app from the "proxy" section of the config is used --
-- an error is thrown if that section is missing.
--
-- If the request contains a @X-Thentos-Session@ header, we validate the session and set the
-- @X-Thentos-User@ and @X-Thentos-Groups@ headers accordingly. Otherwise the request is
-- forwarded as an anonymous request (no user logged in).
--
-- The first parameter is a function that can be used to rename the Thentos-specific headers.
-- To stick with the default names, use 'Thentos.Backend.Core.renderThentosHeaderName'.
getRqMod :: (db `Ex` DB) => RenderHeaderFun -> S.Request -> Action db RqMod
getRqMod renderHeaderFun req = do
    thentosConfig <- getConfig'P
    let mTok = lookupThentosHeaderSession renderHeaderFun req

    (sid, target) <- case lookupThentosHeaderService renderHeaderFun req of
        Just s  -> findTargetForServiceId s thentosConfig
        Nothing -> findDefaultServiceIdAndTarget thentosConfig

    hdrs <- createCustomHeaders renderHeaderFun mTok sid
    let rqMod = RqMod target hdrs
    logger'P DEBUG $ "forwarding proxy request with modifier: " ++ show rqMod
    return rqMod

-- | Look up the target URL for requests based on the given service ID. This requires a "proxies"
-- section in the config. An error is thrown if this section is missing or doesn't contain a match.
-- For convenience, both service ID and target URL are returned.
findTargetForServiceId :: (db `Ex` DB) =>
    ServiceId -> ThentosConfig -> Action db (ServiceId, ProxyUri)
findTargetForServiceId sid conf = do
    target <- case Map.lookup sid (getProxyConfigMap conf) of
            Just proxy -> return $ extractTargetUrl proxy
            Nothing    -> throwError . thentosErrorFromParent $ ProxyNotConfiguredForService sid
    return (sid, target)

-- | Look up the service ID and target URL in the "proxy" section of the config.
-- An error is thrown if that section is missing.
findDefaultServiceIdAndTarget :: (db `Ex` DB) => ThentosConfig -> Action db (ServiceId, ProxyUri)
findDefaultServiceIdAndTarget conf = do
    defaultProxy <- maybe (throwError . thentosErrorFromParent $ MissingServiceHeader) return $
        Tagged <$> conf >>. (Proxy :: Proxy '["proxy"])
    sid <- return . ServiceId $ defaultProxy >>. (Proxy :: Proxy '["service_id"])
    return (sid, extractTargetUrl defaultProxy)

-- | Create headers identifying the user and their groups.
-- Returns an empty list in case of an anonymous request.
createCustomHeaders :: (db `Ex` DB) =>
    RenderHeaderFun -> Maybe ThentosSessionToken -> ServiceId -> Action db T.RequestHeaders
createCustomHeaders _ Nothing _                    = return []
createCustomHeaders renderHeaderFun (Just tok) sid = do
    (uid, user) :: (UserId, User)
        <- do
            session <- lookupThentosSession tok
            case session ^. thSessAgent of
                UserA uid  -> lookupUser uid
                ServiceA servId -> throwError . thentosErrorFromParent $ NeedUserA tok servId

    groups :: [Group] <- userGroups uid sid

    return [ (renderHeaderFun ThentosHeaderUser, cs . fromUserName $ user ^. userName)
           , (renderHeaderFun ThentosHeaderGroups, cs $ show groups)
           ]
