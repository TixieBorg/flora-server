module FloraWeb.Server where

import Colourista.IO (blueMessage)
import Control.Monad
import Control.Monad.Reader
import Data.Maybe
import Data.Text.Display
import Network.Wai
import Network.Wai.Handler.Warp
import Network.Wai.Logger (withStdoutLogger)
import Network.Wai.Middleware.Heartbeat (heartbeatMiddleware)
import Optics.Operators
import qualified Prometheus
import Prometheus.Metric.GHC (ghcMetrics)
import Prometheus.Metric.Proc
import Servant
import Servant.Server.Experimental.Auth
import Servant.Server.Generic

import Flora.Environment
import FloraWeb.Routes
import qualified FloraWeb.Routes.Pages as Pages
import FloraWeb.Server.Auth
import FloraWeb.Server.Logging.Metrics
import FloraWeb.Server.Logging.Tracing
import qualified FloraWeb.Server.Pages as Pages
import FloraWeb.Types

runFlora :: IO ()
runFlora = do
  env <- getFloraEnv
  let baseURL = "http://localhost:" <> display (httpPort env)
  blueMessage $ "🌺 Starting Flora server on " <> baseURL
  when (isJust $ env ^. #logging ^. #sentryDSN) (blueMessage "📋 Connected to Sentry endpoint")
  when (env ^. #logging ^. #prometheusEnabled) $ do
    blueMessage $ "📋 Service Prometheus metrics on " <> baseURL <> "/metrics"
    Prometheus.register ghcMetrics
    void $ Prometheus.register procMetrics
  runServer env

runServer :: FloraEnv -> IO ()
runServer floraEnv = withStdoutLogger $ \logger -> do
  let server = genericServeTWithContext
                 (naturalTransform floraEnv) floraServer (genAuthServerContext floraEnv)
  let warpSettings = setPort (fromIntegral $ httpPort floraEnv ) $
                     setLogger logger $
                     setOnException (sentryOnException (floraEnv ^. #environment)
                                                       (floraEnv ^. #logging))
                     defaultSettings
  runSettings warpSettings $
    prometheusMiddleware (floraEnv ^. #environment) (floraEnv ^. #logging)
    . heartbeatMiddleware
    $ server

floraServer :: Routes (AsServerT FloraM)
floraServer = Routes
  { assets = serveDirectoryWebApp "./static"
  , pages = \session ->
      hoistServer
        (Proxy @Pages.Routes)
        (withReaderT (const session))
        Pages.server
  }

naturalTransform :: FloraEnv -> FloraM a -> Handler a
naturalTransform env app =
  runReaderT app env

genAuthServerContext :: FloraEnv -> Context '[AuthHandler Request Session]
genAuthServerContext floraEnv = authHandler floraEnv :. EmptyContext
