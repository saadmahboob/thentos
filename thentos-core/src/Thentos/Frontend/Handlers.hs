{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE KindSignatures        #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE TypeSynonymInstances  #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

module Thentos.Frontend.Handlers where

import Control.Lens ((.~), (^.))
import Control.Monad.Except (catchError, throwError)
import Control.Monad.Reader (lift)
import Control.Monad.State (get, modify)
import Data.String.Conversions (ST, (<>))
import Data.Proxy (Proxy(Proxy))
import GHC.TypeLits (Symbol)
import Servant.Missing (HasForm(..), FormGet, FormPost)
import Servant (QueryParam, (:<|>)((:<|>)), (:>), Get, Post, ServerT)
import URI.ByteString (RelativeRef(RelativeRef), Query(Query))

import qualified System.Log
import qualified Text.Blaze.Html5 as H

import Thentos.Action
import Thentos.Action.Core
import Thentos.Frontend.Handlers.Combinators
import Thentos.Frontend.Pages
import Thentos.Frontend.State
import Thentos.Frontend.Types
import Thentos.Types

import qualified Thentos.Action.SimpleAuth as U
import qualified Thentos.Action.Unsafe as U


-- import Text.Digestive.View (View)
-- import qualified Control.Monad.State.Class


-- * forms

-- FIXME: 'HtmlForm', 'htmlForm' should go to servant-digestive package, (requires generalization).

type HtmlForm (name :: Symbol) =
       FormGet name
  :<|> FormPost name :> Post '[HTM] H.Html

htmlForm :: forall fn.
        (HasForm fn, FormRendered fn ~ H.Html, FormActionState fn ~ FrontendSessionData)
      => Proxy fn -> (FormContent fn -> FAction H.Html) -> ServerT (HtmlForm fn) FAction
htmlForm proxy postHandler = (clearAllFrontendMsgs >> get) :<|> postHandler'
  where
    postHandler' (Right t) = postHandler t
    postHandler' (Left v)  = do
        state <- get
        return $ formView proxy state v (formAction proxy)


-- * register (thentos)

type UserRegisterH = "register" :> HtmlForm "UserRegister"

instance HasForm "UserRegister" where
    type FormRendered    "UserRegister" = H.Html
    type FormContentType "UserRegister" = HTM
    type FormContent     "UserRegister" = UserFormData
    type FormActionState "UserRegister" = FrontendSessionData

    formAction _  = "/user/register"
    isForm _      = userRegisterForm
    formView _    = userRegisterPage
    formBackend _ = error "HasForm UserRegister formBackend: impossible"

userRegisterH :: ServerT UserRegisterH FAction
userRegisterH = htmlForm (Proxy :: Proxy "UserRegister") $ \userFormData -> do
    fcfg <- getFrontendConfig
    loggerF ("registering new user: " ++ show (udName userFormData))
    (_, tok) <- lift $ addUnconfirmedUser userFormData
    let url = emailConfirmUrl fcfg "/user/register_confirm" (fromConfirmationToken tok)

    sendUserConfirmationMail userFormData url
    userRegisterRequestedPage <$> get

sendUserConfirmationMail :: UserFormData -> ST -> FAction ()
sendUserConfirmationMail user callbackUrl = liftU $
    U.sendMail Nothing (udEmail user) subject message
  where
    message = "Please go to " <> callbackUrl <> " to confirm your account."
    subject = "Thentos account creation confirmation"

sendUserExistsMail :: UserEmail -> FAction ()
sendUserExistsMail address = liftU $
    U.sendMail Nothing address subject message
  where
    message = "Someone tried to sign up to Thentos with your email address"
                <> "\nThis is a reminder that you already have a Thentos"
                <> " account. If you haven't tried to sign up to Thentos, you"
                <> " can just ignore this email. If you have, you are hereby"
                <> " reminded that you already have an account."
    subject = "Attempted Thentos Signup"


type UserRegisterConfirmH = "register_confirm" :>
    QueryParam "token" ConfirmationToken :> Get '[HTM] H.Html

defaultUserRoles :: [Role]
defaultUserRoles = [RoleUser, RoleUserAdmin, RoleServiceAdmin]

userRegisterConfirmH :: ServerT UserRegisterConfirmH FAction
userRegisterConfirmH Nothing = crash FActionErrorNoToken
userRegisterConfirmH (Just token) = do
    (uid, sessTok) <- lift $ do
        loggerA $ "received user register confirm token: " ++ show token
        (_uid, _sessTok) <- confirmNewUser token
        loggerA $ "registered new user: " ++ show _uid
        grantAccessRights'P [RoleAdmin]
        mapM_ (assignRole (UserA _uid)) $ defaultUserRoles
        return (_uid, _sessTok)

    sendFrontendMsg $ FrontendMsgSuccess "Registration complete.  Welcome to Thentos!"
    userFinishLoginH (uid, sessTok)


-- * login (thentos)

type UserLoginH = "login" :> HtmlForm "UserLogin"

instance HasForm "UserLogin" where
    type FormRendered    "UserLogin" = H.Html
    type FormContentType "UserLogin" = HTM
    type FormContent     "UserLogin" = (UserName, UserPass)
    type FormActionState "UserLogin" = FrontendSessionData

    formAction _  = "/user/login"
    isForm _      = userLoginForm
    formView _    = userLoginPage
    formBackend _ = error "HasForm UserLogin formBackend: impossible"

userLoginH :: ServerT UserLoginH FAction
userLoginH = htmlForm (Proxy :: Proxy "UserLogin") $ \(uname, passwd) -> do
    (lift (startThentosSessionByUserName uname passwd) >>= userFinishLoginH)
        `catchError` \case
            BadCredentials -> do
                sendFrontendMsgs [FrontendMsgError "Bad username or password."]
                redirectRR $ RelativeRef Nothing "/user/login" (Query []) Nothing
            e -> throwError e

-- | If action yields uid and session token, login.  Otherwise, redirect to login page with a
-- message that asks to try again.
userFinishLoginH :: (UserId, ThentosSessionToken) -> FAction H.Html
userFinishLoginH (uid, tok) = do
    sendFrontendMsg $ FrontendMsgSuccess "Login successful.  Welcome to Thentos!"
    modify $ fsdLogin .~ Just (FrontendSessionLoginData tok uid (Just DashboardTabDetails))
    redirectToDashboardOrService


@@
-- redirectToDashboardOrService is called, the redirect to dashboard is reached, but when the
-- dashboard is hit, the state doesn't appear to be intact: both fsdLogin and fsdMessage behave
-- consistent with being empty.


-- * forgot password

type ResetPasswordRequestH = "reset_password_request" :> HtmlForm "ResetPasswordRequest"

instance HasForm "ResetPasswordRequest" where
    type FormRendered    "ResetPasswordRequest" = H.Html
    type FormContentType "ResetPasswordRequest" = HTM
    type FormContent     "ResetPasswordRequest" = UserEmail
    type FormActionState "ResetPasswordRequest" = FrontendSessionData

    formAction _  = "/user/reset_password_request"
    isForm _      = resetPasswordRequestForm
    formView _    = resetPasswordRequestPage
    formBackend _ = error "HasForm ResetPasswordRequest formBackend: impossible"

resetPasswordRequestH :: ServerT ResetPasswordRequestH FAction
resetPasswordRequestH = htmlForm (Proxy :: Proxy "ResetPasswordRequest") $ \userEmail -> do
    fcfg <- getFrontendConfig
    loggerF ("password reset request: " ++ show userEmail)
    (do
        (user, token) <- lift $ addPasswordResetToken userEmail
        let url = emailConfirmUrl fcfg "/user/reset_password" (fromPasswordResetToken token)
        lift $ sendPasswordResetMail user url
        resetPasswordRequestedPage <$> get)
      `catchError` \case
        NoSuchUser -> resetPasswordRequestedPage <$> get  -- FIXME: send out warning, too?
        e -> throwError e

sendPasswordResetMail :: User -> ST -> Action FActionError ()
sendPasswordResetMail user callbackUrl = U.unsafeAction $ do
    U.sendMail Nothing (user ^. userEmail) subject message
  where
    message = "To set a new password, go to " <> callbackUrl
    subject = "Thentos Password Reset"


type ResetPasswordH =
      "reset_password" :> QueryParam "token" PasswordResetToken :> HtmlForm "ResetPassword"

instance HasForm "ResetPassword" where
    type FormRendered    "ResetPassword" = H.Html
    type FormContentType "ResetPassword" = HTM
    type FormContent     "ResetPassword" = UserPass
    type FormActionState "ResetPassword" = FrontendSessionData

    formAction _  = "/user/reset_password"
    isForm _      = resetPasswordForm
    formView _    = resetPasswordPage
    formBackend _ = error "HasForm ResetPassword formBackend: impossible"

resetPasswordH :: ServerT ResetPasswordH FAction
resetPasswordH Nothing = error "crash FActionErrorNoToken"  -- FIXME: types
resetPasswordH (Just tok) = htmlForm (Proxy :: Proxy "ResetPassword") $ \password -> do
    fcfg <- getFrontendConfig
    lift $ resetPassword tok password
    sendFrontendMsg $ FrontendMsgSuccess "Password changed successfully.  Welcome back to Thentos!"

    -- FIXME: what we would like to do here is login the user right away, with something like
    -- userLoginCallAction $ (uid,) <$> startSessionNoPass (UserA uid)
    redirect' "/dashboard"


-- * logout (thentos)

type UserLogoutH = "logout" :> (Get '[HTM] H.Html :<|> Post '[HTM] H.Html)

userLogoutH :: ServerT UserLogoutH FAction
userLogoutH = userLogoutConfirmH :<|> userLogoutDoneH

userLogoutConfirmH :: FAction H.Html
userLogoutConfirmH = runAsUserOrLogin $ \_ fsl -> do
    serviceNames <- lift $ serviceNamesFromThentosSession (fsl ^. fslToken)
    -- FIXME: do we need csrf protection for this?
    setCurrentDashboardTab DashboardTabLogout
    renderDashboard (userLogoutConfirmSnippet "/user/logout" serviceNames "csrfToken")

userLogoutDoneH :: FAction H.Html
userLogoutDoneH = runAsUserOrLogin $ \_ fsl -> do
    lift $ endThentosSession (fsl ^. fslToken)
    modify $ fsdLogin .~ Nothing
    userLogoutDonePage <$> get


-- * user update

type EmailUpdateH = "update_email" :> HtmlForm "EmailUpdate"

instance HasForm "EmailUpdate" where
    type FormRendered    "EmailUpdate" = H.Html
    type FormContentType "EmailUpdate" = HTM
    type FormContent     "EmailUpdate" = UserEmail
    type FormActionState "EmailUpdate" = FrontendSessionData

    formAction _  = "/user/reset_password_request"
    isForm _      = emailUpdateForm
    formView _    = \fsd v action -> renderDashboard'' $ emailUpdateSnippet fsd v action  -- FIXME: modify $ fslDashboardTab .~ DashBoardDetails
    formBackend _ = error "HasForm EmailUpdate formBackend: impossible"

-- FIXME: csrf?
emailUpdateH :: ServerT EmailUpdateH FAction
emailUpdateH = htmlForm (Proxy :: Proxy "EmailUpdate") $ \userEmail -> do
    loggerF ("email change request: " ++ show userEmail)
    fcfg <- getFrontendConfig
    let go = do
          runAsUserOrLogin $ \_ fsl -> lift
              . requestUserEmailChange (fsl ^. fslUserId) userEmail
                  $ emailConfirmUrl fcfg "/user/update_email_confirm" . fromConfirmationToken
          emailSent

    go `catchError`
        \case UserEmailAlreadyExists -> emailSent
              e                      -> throwError e
  where
    emailSent = do
        sendFrontendMsgs $
            FrontendMsgSuccess "Your new email address has been stored." :
            FrontendMsgSuccess "It will be activated once you process the confirmation email." :
            []
        redirect' "/dashboard"


type EmailUpdateConfirmH = "update_email_confirm" :>
    QueryParam "token" ConfirmationToken :> Get '[HTM] H.Html

emailUpdateConfirmH :: ServerT EmailUpdateConfirmH FAction
emailUpdateConfirmH Nothing = crash FActionErrorNoToken
emailUpdateConfirmH (Just token) = go `catchError`
      \case NoSuchToken -> crash FActionErrorNoToken
            e           -> throwError e
  where
    go = do
        lift $ confirmUserEmailChange token
        sendFrontendMsg (FrontendMsgSuccess "Change email: success!")
        redirect' "/dashboard"


type PasswordUpdateH = "update_password" :> HtmlForm "PasswordUpdate"

instance HasForm "PasswordUpdate" where
    type FormRendered    "PasswordUpdate" = H.Html
    type FormContentType "PasswordUpdate" = HTM
    type FormContent     "PasswordUpdate" = (UserPass, UserPass)
    type FormActionState "PasswordUpdate" = FrontendSessionData

    formAction _  = "/user/update_password"
    isForm _      = passwordUpdateForm
    formView _    = \fsd v action -> renderDashboard'' $ passwordUpdateSnippet fsd v action  -- FIXME: modify $ fslDashboardTab .~ DashBoardDetails
    formBackend _ = error "HasForm PasswordUpdate formBackend: impossible"


passwordUpdateH :: ServerT PasswordUpdateH FAction
passwordUpdateH = htmlForm (Proxy :: Proxy "PasswordUpdate") $ \(oldPass, newPass) -> do
    loggerF ("password change request.")
    let go = runAsUserOrLogin $ \_ fsl -> lift $ changePassword (fsl ^. fslUserId) oldPass newPass
        worked = sendFrontendMsg (FrontendMsgSuccess "Change password: success!") >> redirect' "/dashboard"
        didn't = sendFrontendMsg (FrontendMsgError "Invalid old password.") >> redirect' "/user/update_password"

    (go >> worked) `catchError`
      \case BadCredentials -> didn't
            e              -> throwError e


-- * services

{-

serviceCreate :: FH ()
serviceCreate = runAsUser $ \ _ fsl -> do
    tok <- with sess csrfToken
    runPageletForm serviceCreateForm
                   (serviceCreateSnippet tok) DashboardTabOwnServices
                   $ \ (name, description) -> do
        eResult <- snapRunActionE $ addService (fsl ^. fslUserId) name description
        case eResult of
            Right (sid, key) -> do
                sendFrontendMsgs
                    [ FrontendMsgSuccess "Added a service!"
                    , FrontendMsgSuccess $ "Service id: " <> fromServiceId sid
                    , FrontendMsgSuccess $ "Service key: " <> fromServiceKey key
                    ]
                redirect' "/dashboard" 303
            Left e -> logger INFO (show e) >> crash 400 "Create service: failed."

-- | (By the time this handler is called, serviceLogin has to have been
-- called so we have a callback to the login page stored in the
-- session state.)
serviceRegister :: FH ()
serviceRegister = runAsUser $ \ _ fsl -> do
    ServiceLoginState sid rr <- getServiceLoginState >>= maybe (crash $ FActionError500 "Service login: no state.") return

    let present :: ST -> View H.Html -> FH ()
        present formAction view = do
            (_, user)    <- snapRunAction (lookupConfirmedUser (fsl ^. fslUserId))
            (_, service) <- snapRunActionE (lookupService sid)
                        >>= either (\ e -> crash $ FActionError500 (e, "Service registration: misconfigured service (no service id).")) return
            -- FIXME: we are doing a lookup on the service table, but
            -- the service may have an opinion on whether the user is
            -- allowed to look it up.  the user needs to present a
            -- cryptographic proof of the service's ok for lookup
            -- here.
            tok <- with sess csrfToken
            blaze $ serviceRegisterPage tok formAction view sid service user

        process :: () -> FH ()
        process () = do
            eResult <- snapRunActionE $ addServiceRegistration (fsl ^. fslToken) sid
            case eResult of
                Right () -> redirectRR rr
                -- (We match the '()' explicitly here just
                -- because we can, and because nobody has to
                -- wonder what's hidden in the '_'.  No
                -- lazyless counter-magic is involved.)

                Left e -> crash $ FActionError500 (e, "Service registration: error.")
                -- ("Unknown service id" should have been
                -- caught in the "render form" case.  Perhaps
                -- the user has tampered with the cookie?)

    runHandlerForm serviceRegisterForm present process

-- | Coming from a service site, handle the authentication and
-- redirect to service with valid session token.  This may happen in a
-- series of redirects through the thentos frontend; the state of this
-- series is stored in `fsdServiceLoginState`.
--
-- FIXME[mf] (thanks to Sönke Hahn): The session token seems to be
-- contained in the url. So if people copy the url from the address
-- bar and send it to someone, they will get the same session.  The
-- session token should be in a cookie, shouldn't it?
serviceLogin :: FH ()
serviceLogin = do
    ServiceLoginState sid _ <- setServiceLoginState

    let -- case A: user is not logged into thentos.  we have stored
        -- service login callback already at this point, so just
        -- redirect to login page.
        notLoggedIn :: FH ()
        notLoggedIn = redirect' "/user/login" 303

        loggedIn :: FrontendSessionLoginData -> FH ()
        loggedIn fsl = do
            let tok = fsl ^. fslToken
            eSessionToken :: Either (ActionError Void) ServiceSessionToken
                <- snapRunActionE $ startServiceSession tok sid

            case eSessionToken of
                -- case B: user is logged into thentos and registered
                -- with service.  clean up the 'ServiceLoginState'
                -- stash in thentos session state, extract the
                -- callback URI from the request parameters, inject
                -- the session token we just created, and redirect.
                Right (ServiceSessionToken sessionToken) -> do
                    _ <- popServiceLoginState
                    let f = uriQueryL . queryPairsL %~ (("token", cs sessionToken) :)
                    meCallback <- parseURI laxURIParserOptions <$$> getParam "redirect"
                    case meCallback of
                        Just (Right callback) -> redirectURI $ f callback
                        Just (Left _)         -> crash FActionErrorServiceLoginNoCallbackUrl
                        Nothing               -> crash FActionErrorServiceLoginNoCallbackUrl

                -- case C: user is logged into thentos, but not
                -- registered with service.  redirect to service
                -- registration page.
                Left (ActionErrorThentos NotRegisteredWithService) -> do
                    redirect' "/service/register" 303

                -- case D: user is logged into thentos, but something
                -- unexpected went wrong (possibly the session was
                -- corrupted by the user/adversary?).  report error to
                -- log file and user.
                Left e -> do
                    crash $ FActionError500 "Service login: could not initiate session."

    runAsUserOrNot (\ _ -> loggedIn) notLoggedIn
-}


-- | If a service login state exists, consume it, jump back to the
-- service, and log in.  If not, jump to `/dashboard`.
redirectToDashboardOrService :: FAction H.Html
redirectToDashboardOrService = do
    mCallback <- popServiceLoginState
    case mCallback of
        Just (ServiceLoginState _ rr) -> redirectRR rr
        Nothing                       -> redirect' "/dashboard"


-- * Cache control

{-

-- | Disable response caching. The wrapped handler can overwrite this by
-- setting its own cache control headers.
--
-- Cache-control headers are only added to GET and HEAD responses since other request methods
-- are considered uncachable by default.
--
-- Note that, though this handler is always called, its actions are sometimes discarded by Snap,
-- e.g. if the 'error' function is called. That leads to an 500 Internal Server Error responses
-- *without* the additional headers added by this handler. This may not be so bad since (a)
-- we don't want to return any error 500 pages and (b) they are considered uncacheable anyway.
-- But it's something to keep in mind.
--
-- According to the HTTP 1.1 Spec, GET/HEAD responses with the following error codes (>= 400) may
-- be cached unless forbidded by cache-control headers:
--
-- * 404 Not Found
-- * 405 Method Not Allowed
-- * 410 Gone
-- * 414 Request-URI Too Long
-- * 501 Not Implemented
--
-- The 'unknownPath' handler takes care of 404 responses. The other cacheable response types will
-- probably rarely be generated by Snap, but we should keep an eye on them.
disableCaching :: Handler b v a -> Handler b v a
disableCaching h = do
    req <- getRequest
    when (rqMethod req `elem` [GET, HEAD]) addCacheControlHeaders
    h
  where
    addCacheControlHeaders =
        modifyResponse $ setHeader "Cache-Control" "no-cache, no-store, must-revalidate"
                       . setHeader "Expires" "0"

-}
