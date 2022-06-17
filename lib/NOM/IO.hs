module NOM.IO (interact, processTextStream) where

import Relude

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (concurrently_, race_)
import Control.Concurrent.STM (check, modifyTVar, swapTVar)
import Control.Exception (IOException, try)
import Data.ByteString qualified as ByteString
import Data.Text qualified as Text
import Data.Time (ZonedTime, getZonedTime)
import System.IO qualified

import Streamly.Data.Fold qualified as Fold
import Streamly.Prelude ((.:))
import Streamly.Prelude qualified as Stream

import System.Console.ANSI (SGR (Reset), setSGRCode)

import NOM.Error (NOMError (InputError))
import NOM.Print.Table as Table (bold, displayWidth, markup, red, truncate, displayWidthBS)
import NOM.Update.Monad (UpdateMonad)
import NOM.Util ((.>), (|>))
import Data.Attoparsec.ByteString (Parser)
import NOM.IO.ParseStream (parseStream)
import Data.ByteString.Char8 qualified as ByteString
import System.Console.ANSI qualified as Terminal
import System.Console.Terminal.Size qualified as Terminal.Size

type Stream = Stream.SerialT IO
type Output = Text
type UpdateFunc update state = forall m. UpdateMonad m => (update, ByteString) -> StateT state m ([NOMError], ByteString)
type OutputFunc state = state -> Maybe Window -> ZonedTime -> Output
type Finalizer state = forall m. UpdateMonad m => StateT state m ()
type Window = Terminal.Size.Window Int

readTextChunks :: Handle -> Stream (Either NOMError ByteString)
readTextChunks handle = loop
 where
  -- We read up-to 4kb of input at once. We will rarely need more than that for one succesful parse (i.e. a line).
  -- I don‘t know much about computers, but 4k seems like something which would be cached efficiently.
  bufferSize :: Int
  bufferSize = 4096
  tryRead :: Stream (Either IOException ByteString)
  tryRead = liftIO $ try $ ByteString.hGetSome handle bufferSize
  loop :: Stream (Either NOMError ByteString)
  loop =
    tryRead >>= \case
      Left err -> Left (InputError err) .: loop -- Ignore Exception
      Right "" -> mempty -- EOF
      Right input -> Right input .: loop

runUpdate ::
  forall update state.
  TVar ByteString ->
  TVar state ->
  UpdateFunc update state ->
  (update, ByteString) ->
  IO ByteString
runUpdate bufferVar stateVar updater input = do
  oldState <- readTVarIO stateVar
  ((!errors, !output), !newState) <- runStateT (updater input) oldState
  atomically $ do
    forM_ errors (\error' -> modifyTVar bufferVar (appendError error'))
    writeTVar stateVar newState
  pure output

writeStateToScreen :: forall state. TVar Int -> TVar state -> TVar ByteString -> (state -> state) -> OutputFunc state -> IO ()
writeStateToScreen linesVar stateVar bufferVar maintenance printer = do
  now <- getZonedTime
  terminalSize <- Terminal.Size.size

  (!lastPrintedLineCount, reflowLineCountCorrection, linesToPad, nixOutput, nomOutput) <- atomically do
    unprepared_nom_state <- readTVar stateVar
    let prepared_nom_state = maintenance unprepared_nom_state
        nomOutput = ByteString.lines $ encodeUtf8 $ truncateOutput terminalSize (printer prepared_nom_state terminalSize now)
        nomOutputLength = length nomOutput
    writeTVar stateVar prepared_nom_state
    lastPrintedLineCount <- readTVar linesVar
    nixOutput <- ByteString.lines <$> swapTVar bufferVar mempty

    -- We will try to calculate how many lines we can draw without reaching the end
    -- of the screen so that we can avoid flickering redraws triggered by
    -- printing a newline.
    -- For the output passed through from Nix the lines could be to long leading
    -- to reflow by the terminal and therefor messing with our line count.
    -- We try to predict the number of introduced linebreaks here. The number
    -- might be slightly to high in corner cases but that will only trigger
    -- sligthly more redraws which is totally acceptable.
    let reflowLineCountCorrection = do
          terminalSize' <- terminalSize
          pure $ getSum $ foldMap (\line -> Sum (displayWidthBS line `div` terminalSize'.width)) nixOutput
        -- When the nom output suddenly gets smaller, it might jump up from the bottom of the screen.
        -- To prevent this we insert a few newlines before it.
        -- We only do this if we know the size of the terminal.
        linesToPad = fromMaybe 0 do
          reflowCorrection <- reflowLineCountCorrection
          let nixOutputLength = reflowCorrection + length nixOutput
          pure $ max 0 (lastPrintedLineCount - nixOutputLength - nomOutputLength)
        lineCountToPrint = nomOutputLength + linesToPad
    writeTVar linesVar lineCountToPrint
    -- We pass a lot of variables out of the STM call here to prevent
    -- congestion.  It’s probably not super relevant because the most expensive
    -- call here is probably `printer` a few lines above.
    pure (lastPrintedLineCount, reflowLineCountCorrection, linesToPad, nixOutput, nomOutput)

  let 
    outputToPrint = nixOutput <> mtimesDefault linesToPad [""] <> nomOutput
    -- We have Strict enabled and at this point we are using force to make sure
    -- the whole output has been calculated before we clear the screen.
    outputToPrintWithNewlineAnnotations = force (zip (whatNewLine lastPrintedLineCount reflowLineCountCorrection <$> [0..])) outputToPrint
  
  -- Clear last output from screen.
  -- First we clear the current line, if we have written on it.
  when (lastPrintedLineCount > 0) Terminal.clearLine

  -- Then, if necessary we, move up and clear more lines.
  replicateM_ (lastPrintedLineCount - 1) do
    Terminal.cursorUpLine 1 -- Moves cursor one line up and to the beginning of the line.
    Terminal.clearLine -- We are avoiding to use clearFromCursorToScreenEnd
                       -- because it apparently triggers a flush on some terminals.

  -- when we have cleared the line, but not used cursorUpLine, the cursor needs to be moved to the start for printing.
  when (lastPrintedLineCount == 1) do Terminal.setCursorColumn 0

  -- Write new output to screen.
  forM_ outputToPrintWithNewlineAnnotations \(newline, line) -> do
    case newline of
      NoNewLine -> pass
      MoveNewLine -> Terminal.cursorDownLine 1
      PrintNewLine -> ByteString.putStr "\n"
    ByteString.putStr line

  System.IO.hFlush stdout

-- Depending on the current line of the output we are printing we need to decide
-- how to move to a new line before printing.
whatNewLine :: Int -> Maybe Int -> Int -> NewLine
whatNewLine _ Nothing = \case
 -- When we have no info about terminal size, better be careful and always print
 -- newlines if necessary.
 0 -> NoNewLine
 _ -> PrintNewLine
whatNewLine previousPrintedLines (Just correction) = \case
 -- When starting to print we are always in an empty line with the cursor at the start.
 -- So we don‘t need to go to a new line
 0 -> NoNewLine
 -- When the current offset is smaller than the number of previously printed lines.
 -- e.g. we have printed 1 line, but before we had printed 2
 -- then we can probably move the cursor a row down without needing to print a newline.
 x |
  x + correction < previousPrintedLines -> MoveNewLine
 -- When we are at the bottom of the terminal we have no choice but need to
 -- print a newline and thus (sadly) flush the terminal
 _ -> PrintNewLine

data NewLine = NoNewLine | MoveNewLine | PrintNewLine
  deriving stock Generic
  deriving anyclass NFData

interact ::
  forall update state.
  Parser update ->
  UpdateFunc update state ->
  (state -> state) ->
  OutputFunc state ->
  Finalizer state ->
  state ->
  IO state
interact parser updater maintenance printer finalize initialState =
  readTextChunks stdin
    |> processTextStream parser updater maintenance (Just printer) finalize initialState

-- frame durations are passed to threadDelay and thus are given in microseconds

maxFrameDuration :: Int
maxFrameDuration = 1_000_000 -- once per second to update timestamps

minFrameDuration :: Int
minFrameDuration =
 -- this seems to be a nice compromise to reduce excessive
 -- flickering, since the movement is not continuous this low frequency doesn‘t
 -- feel to sluggish for the eye, for me.
   100_000 -- 10 times per second

processTextStream ::
  forall update state.
  Parser update ->
  UpdateFunc update state ->
  (state -> state) ->
  Maybe (OutputFunc state) ->
  Finalizer state ->
  state ->
  Stream (Either NOMError ByteString) ->
  IO state
processTextStream parser updater maintenance printerMay finalize initialState inputStream = do
  stateVar <- newTVarIO initialState
  bufferVar <- newTVarIO mempty
  let
      keepProcessing :: IO ()
      keepProcessing =
        inputStream
          |> Stream.tap (writeErrorsToBuffer bufferVar)
          .> Stream.mapMaybe rightToMaybe
          .> parseStream parser
          .> Stream.mapM (snd .> runUpdate bufferVar stateVar updater >=> flip (<>) .> modifyTVar bufferVar .> atomically)
          .> Stream.drain
      waitForInput :: IO ()
      waitForInput = atomically $ check . not . ByteString.null =<< readTVar bufferVar
  printerMay |> maybe keepProcessing \printer -> do
    linesVar <- newTVarIO 0
    let writeToScreen :: IO ()
        writeToScreen = writeStateToScreen linesVar stateVar bufferVar maintenance printer
        keepPrinting :: IO ()
        keepPrinting = forever do
          race_ (concurrently_ (threadDelay minFrameDuration) waitForInput) (threadDelay maxFrameDuration)
          writeToScreen
    race_ keepProcessing keepPrinting
    readTVarIO stateVar >>= execStateT finalize >>= writeTVar stateVar .> atomically
    writeToScreen
  readTVarIO stateVar |> (if isNothing printerMay then (>>= execStateT finalize) else id)

writeErrorsToBuffer :: TVar ByteString -> Fold.Fold IO (Either NOMError ByteString) ()
writeErrorsToBuffer bufferVar = Fold.drainBy saveInput
 where
  saveInput :: Either NOMError ByteString -> IO ()
  saveInput = \case
    Left error' -> atomically $ modifyTVar bufferVar (appendError error')
    _ -> pass

appendError :: NOMError -> ByteString -> ByteString
appendError err prev = (if ByteString.null prev || ByteString.isSuffixOf "\n" prev then "" else "\n") <> nomError <> show err <> "\n"

nomError :: ByteString
nomError = encodeUtf8 (markup (red . bold) "nix-output-monitor internal error: ")

truncateOutput :: Maybe Window -> Text -> Text
truncateOutput win output = maybe output go win
 where
  go :: Window -> Text
  go window = Text.intercalate "\n" $ truncateColumns window.width <$> truncateRows window.height

  truncateColumns :: Int -> Text -> Text
  truncateColumns columns line = if displayWidth line > columns then Table.truncate (columns - 1) line <> "…" <> toText (setSGRCode [Reset]) else line

  truncateRows :: Int -> [Text]
  truncateRows rows
    | length outputLines >= rows - outputLinesToAlwaysShow = take 1 outputLines <> [" ⋮ "] <> drop (length outputLines + outputLinesToAlwaysShow + 2 - rows) outputLines
    | otherwise = outputLines

  outputLines :: [Text]
  outputLines = Text.lines output

outputLinesToAlwaysShow :: Int
outputLinesToAlwaysShow = 5
