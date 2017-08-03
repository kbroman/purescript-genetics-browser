module Genetics.Browser.UI.Container
       where

import Prelude
import Control.Coroutine as CR
import Control.Monad.Aff as Aff
import Control.Monad.Aff.Bus as Bus
import Genetics.Browser.Biodalliance as Biodalliance
import Genetics.Browser.Cytoscape as Cytoscape
import Genetics.Browser.Renderer.GWAS as GWAS
import Genetics.Browser.Renderer.Lineplot as QTL
import Genetics.Browser.UI.Biodalliance as UIBD
import Genetics.Browser.UI.Cytoscape as UICy
import Halogen as H
import Halogen.Aff as HA
import Halogen.Component.ChildPath as CP
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Control.Monad.Aff (Aff, Canceler(..), forkAff)
import Control.Monad.Aff.AVar (AVAR)
import Control.Monad.Aff.Bus (BusR, BusRW)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Eff.Console (CONSOLE, log)
import Control.Monad.Except (runExcept)
import Control.Monad.Rec.Class (forever)
import DOM.HTML.Types (HTMLElement)
import Data.Argonaut (_Number, _Object, _String, (.?))
import Data.Argonaut.Core (JObject)
import Data.Array (null, uncons, (:))
import Data.Const (Const)
import Data.Either (Either(..))
import Data.Either.Nested (Either2, Either1)
import Data.Foldable (foldMap, sequence_)
import Data.Foreign (Foreign, renderForeignError)
import Data.Functor.Coproduct.Nested (type (<\/>))
import Data.Lens (re, (^?))
import Data.Lens.Index (ix)
import Data.Maybe (Maybe(Just, Nothing), maybe)
import Data.Newtype (unwrap, wrap)
import Data.Options (Options, (:=))
import Data.Symbol (SProxy(..))
import Data.Traversable (traverse_)
import Data.Tuple (fst)
import Data.Variant (Variant, case_, default, inj, on)
import Genetics.Browser.Biodalliance (RendererInfo, initBD, renderers, setLocation, sources)
import Genetics.Browser.Config (BrowserConfig(..), parseBrowserConfig)
import Genetics.Browser.Config.Track (CyGraphConfig, validateConfigs)
import Genetics.Browser.Cytoscape (ParsedEvent(..))
import Genetics.Browser.Cytoscape.Collection (filter, connectedNodes, isEdge, isNode, sourceNodes, targetNodes)
import Genetics.Browser.Cytoscape.Types (CY, Cytoscape, Element, elementJObject)
import Genetics.Browser.Events (Event(..), Location, Range)
import Genetics.Browser.Events.Handler (InputHandler(..), OutputHandler(..), appendInputHandler, appendOutputHandler, applyOutputHandler, emptyInputHandler, emptyOutputHandler, forkInputHandler)
import Genetics.Browser.Renderer.Lineplot (LinePlotConfig)
import Genetics.Browser.Types (BD, Biodalliance, Renderer)
import Genetics.Browser.Units (Bp(Bp), Chr(Chr), _Bp, _BpMBp, _Chr, _MBp, bp)
import Global.Unsafe (unsafeStringify)
import Halogen.VDom.Driver (runUI)
import Unsafe.Coerce (unsafeCoerce)


type BDEventEff eff = (console :: CONSOLE, bd :: BD, avar :: AVAR | eff)
type CYEventEff eff = (console :: CONSOLE, cy :: CY, avar :: AVAR | eff)

type BDHandlerOutput = Biodalliance -> Eff (BDEventEff ()) Unit
type CyHandlerOutput = Cytoscape -> Eff (CyEventEff ()) Unit


locationInputBD :: InputHandler (location :: Location) (location :: Location -> BDHandlerOutput) BDHandlerOutput
locationInputBD = appendInputHandler (SProxy :: SProxy "location") f emptyInputHandler
  where f loc bd = do
            log "bd got location"
            setLocation bd loc.chr (bp loc.pos - Bp 1000000.0) (bp loc.pos + Bp 1000000.0)

rangeInputBD :: InputHandler ( range :: Range, location :: Location ) _ BDHandlerOutput
rangeInputBD = appendInputHandler (SProxy :: SProxy "range") f locationInputBD
  where f :: Range -> BDHandlerOutput
        f ran bd = do
            log "bd got range"
            setLocation bd ran.chr ran.minPos ran.maxPos


type CyEventEff eff = (console :: CONSOLE, cy :: CY, avar :: AVAR | eff)


rangeInputCy :: InputHandler (range :: Range) _ CyHandlerOutput
rangeInputCy = appendInputHandler (SProxy :: SProxy "range") f emptyInputHandler
  where f ran cy = do
            log "cy got range"
            log $ "chr: " <> show ran.chr
            let pred el = case parseLocationElementCy el of
                  Nothing -> false
                  Just loc -> loc.chr == ran.chr

            graphColl <- liftEff $ Cytoscape.graphGetCollection cy
            let edges = filter ((not $ wrap pred) && isEdge) graphColl

            _ <- liftEff $ Cytoscape.graphRemoveCollection $ targetNodes edges
            pure unit



forkBDInputHandler bd bus = forkInputHandler rangeInputBD bd bus


-- createBDHandler :: forall eff. { location :: Biodalliance -> Location -> Eff _ Unit }
--                                -- , range :: Biodalliance -> Range -> Eff _ Unit }
--                 -> Biodalliance
--                 -> BusRW (Variant (location :: Location))
--                 -> Aff _ (Canceler _)
-- createBDHandler {location} bd bus = forkAff $ forever do
--   val <- Bus.read bus
--   liftEff $ (default (pure unit)
--     # on (SProxy :: SProxy "location") (location bd)
--     -- # on (SProxy :: SProxy "range") (range bd)
--     ) val

forkCyInputHandler cy bus = forkInputHandler rangeInputCy cy bus

createCyHandler :: forall eff. { range :: Cytoscape -> Range -> Eff _ Unit }
                -> Cytoscape
                -> BusRW (Variant (range :: Range))
                -> Aff _ (Canceler _)
createCyHandler {range} cy bus = forkAff $ forever do
  val <- Bus.read bus
  liftEff $ (default (pure unit)
    # on (SProxy :: SProxy "range") (range cy)
    ) val


rangeEventOutputBD :: OutputHandler JObject (range :: Range)
rangeEventOutputBD = appendOutputHandler (SProxy :: SProxy "range") f emptyOutputHandler
  where f obj =  do
              chr <- obj ^? ix "chr" <<< _String <<< re _Chr
              minPos <- obj ^? ix "min" <<< _Number <<< re _Bp
              maxPos <- obj ^? ix "max" <<< _Number <<< re _Bp
              pure $ {chr, minPos, maxPos}



parseLocationElementCy :: Element -> Maybe Location
parseLocationElementCy el = do
    loc <- elementJObject el ^? ix "data" <<< _Object <<< ix "lrsLoc"
    chr <- loc ^? _Object <<< ix "chr" <<< _String <<< re _Chr
            -- ridiculous.
    pos <- loc ^? _Object <<< ix "pos" <<< _Number
                    <<< re _MBp <<< re _BpMBp
    pure $ { chr, pos }


locationEventOutputCy :: OutputHandler ParsedEvent (location :: Location)
locationEventOutputCy = appendOutputHandler (SProxy :: SProxy "location") f emptyOutputHandler
  where f (ParsedEvent ev) = case ev.target of
            Left el -> parseLocationElementCy el
            Right _ -> Nothing



subscribeBDEvents :: _ -> Biodalliance -> _ -> _
subscribeBDEvents h bd bus =
  Biodalliance.addFeatureListener bd $ \obj -> do
    let evs = applyOutputHandler h obj
    traverse_ (\x -> Aff.launchAff $ Bus.write x bus) evs


subscribeCyEvents :: _ -> Cytoscape -> _ -> _
subscribeCyEvents h cy bus =
  Cytoscape.onClick cy $ \obj -> do
    let evs = applyOutputHandler h obj
    traverse_ (\x -> Aff.launchAff $ Bus.write x bus) evs


qtlGlyphify :: LinePlotConfig -> Renderer
qtlGlyphify = QTL.render

gwasGlyphify :: Renderer
gwasGlyphify = GWAS.render


data Track = BDTrack | CyTrack

type State = Unit

data Query a
  = CreateBD (∀ eff. HTMLElement -> Eff (bd :: BD | eff) Biodalliance) a
  | PropagateMessage Message a
  | BDScroll Bp a
  | BDJump Chr Bp Bp a
  | CreateCy String a
  | ResetCy a

data Message
  = BDInstance Biodalliance
  | CyInstance Cytoscape
  -- | WithCy Cytoscape

type ChildSlot = Either2 UIBD.Slot UICy.Slot

type ChildQuery = UIBD.Query <\/> UICy.Query <\/> Const Void
type Effects eff = UIBD.Effects (UICy.Effects eff)

component :: ∀ eff. H.Component HH.HTML Query Unit Message (Aff (Effects eff))
component =
  H.parentComponent
    { initialState: const initialState
    , render
    , eval
    , receiver: const Nothing
    }
  where

  initialState :: State
  initialState = unit

  render :: State -> H.ParentHTML Query ChildQuery ChildSlot (Aff (Effects eff))
  render state =
    HH.div_
      [ HH.div_
        [ HH.button
          [  HE.onClick (HE.input_ (BDScroll (Bp (-1000000.0))))
          ]
          [ HH.text "Scroll left 1MBp" ]
        , HH.button
          [  HE.onClick (HE.input_ (BDScroll (Bp 1000000.0)))
          ]
          [ HH.text "Scroll right 1MBp" ]
        , HH.button
          [  HE.onClick (HE.input_ ResetCy)
          ]
          [ HH.text "Reset cytoscape" ]
          -- these divs are used to control the sizes of the subcomponents without having to query the children
        , HH.div
            [] [HH.slot' CP.cp1 UIBD.Slot UIBD.component unit handleBDMessage]
        , HH.div
            [] [HH.slot' CP.cp2 UICy.Slot UICy.component unit handleCyMessage]
        ]
      ]

  -- addCyGraph :: Maybe CyGraphConfig -> _
  -- addCyGraph = case _ of
  --   Nothing -> []
  --   Just cy -> [HH.div [] [HH.slot' CP.cp2 UICy.Slot UICy.component unit handleCyMessage]]

  handleBDMessage :: UIBD.Message -> Maybe (Query Unit)
  handleBDMessage UIBD.Initialized = Nothing
  handleBDMessage (UIBD.SendBD bd) = Just $ H.action $ PropagateMessage (BDInstance bd)

  -- TODO the event source track should be handled automatically somehow
  handleCyMessage :: UICy.Output -> Maybe (Query Unit)
  handleCyMessage (UICy.SendCy cy) = Just $ H.action $ PropagateMessage (CyInstance cy)
  handleCyMessage (UICy.SendEvent) = Nothing


  eval :: Query ~> H.ParentDSL State Query ChildQuery ChildSlot Message (Aff (Effects eff))
  eval = case _ of
    CreateBD bd next -> do
      _ <- H.query' CP.cp1 UIBD.Slot $ H.action (UIBD.Initialize bd)
      pure next

    PropagateMessage msg next -> do
      case msg of
        BDInstance _ -> liftEff $ log "propagating BD"
        CyInstance _ -> liftEff $ log "propagating Cy"
      H.raise msg
      pure next

    BDScroll dist next -> do
      _ <- H.query' CP.cp1 UIBD.Slot $ H.action (UIBD.Scroll dist)
      pure next
    BDJump chr xl xr next -> do
      _ <- H.query' CP.cp1 UIBD.Slot $ H.action (UIBD.Jump chr xl xr)
      pure next

    CreateCy div next -> do
      _ <- H.query' CP.cp2 UICy.Slot $ H.action (UICy.Initialize div)
      pure next
    ResetCy next -> do
      _ <- H.query' CP.cp2 UICy.Slot $ H.action UICy.Reset
      pure next



qtlRenderer :: RendererInfo
qtlRenderer = { name: "qtlRenderer"
              , renderer: qtlGlyphify { minScore: 4.0
                                      , maxScore: 6.0
                                      , color: "#ff0000"
                                      }
              , canvasHeight: 200.0
              }

gwasRenderer :: RendererInfo
gwasRenderer = { name: "gwasRenderer"
               , renderer: gwasGlyphify
               , canvasHeight: 300.0
               }

bdOpts :: Options Biodalliance
bdOpts = renderers := [ qtlRenderer, gwasRenderer ]


main :: Foreign -> Eff _ Unit
main fConfig = HA.runHalogenAff do
  case runExcept $ parseBrowserConfig fConfig of
    Left e -> liftEff $ do
      log "Invalid browser configuration:"
      sequence_ $ log <<< renderForeignError <$> e

    Right (BrowserConfig config) -> do
      let {bdTracks, cyGraphs} = validateConfigs config.tracks

          opts' = bdOpts <> sources := bdTracks.results

      liftEff $ log $ "BDTrack errors: " <> foldMap ((<>) ", ") bdTracks.errors
      liftEff $ log $ "CyGraph errors: " <> foldMap ((<>) ", ") cyGraphs.errors

      let mkBd :: (∀ eff. HTMLElement -> Eff (bd :: BD | eff) Biodalliance)
          mkBd = initBD opts' config.wrapRenderer config.browser


      liftEff $ log "running main"
      HA.awaitLoad
      el <- HA.selectElement (wrap "#psgbHolder")

      case el of
        Nothing -> do
          liftEff $ log "no element for browser!"
        Just el' -> do

          io <- runUI component unit el'

          busFromBD <- Bus.make
          busFromCy <- Bus.make

          when (not null bdTracks.results) do
            io.subscribe $ CR.consumer $ case _ of
              BDInstance bd -> do
                liftEff $ log "attaching BD event handlers"

                _ <- forkInputHandler rangeInputBD bd busFromCy
                _ <- liftEff $ subscribeBDEvents rangeEventOutputBD bd busFromBD

                pure Nothing
              _ -> pure $ Just unit
            liftEff $ log "creating BD"
            io.query $ H.action (CreateBD mkBd)

            liftEff $ log "created BD!"


          liftEff $ log $ "cytoscape enabled: " <> show (not null cyGraphs.results)
          case uncons cyGraphs.results of
            Nothing -> pure unit
            Just {head, tail} -> do
              io.subscribe $ CR.consumer $ case _ of
                CyInstance cy -> do
                  liftEff $ log "attaching Cy event handlers"
                  _ <- forkInputHandler rangeInputCy cy busFromBD
                  _ <- liftEff $ subscribeCyEvents locationEventOutputCy cy busFromCy
                  pure Nothing
                _ -> pure $ Just unit

              liftEff $ log "creating Cy.js"
              io.query $ H.action (CreateCy $ _.elementsUri <<< unwrap $ head)
              liftEff $ log "created cy!"
