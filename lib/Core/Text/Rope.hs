{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs #-}

{-|
If you're accustomed to working with text in almost any other programming
language, you'd be aware that a \"string\" typically refers to an in-memory
/array/ of characters. Traditionally this was a single ASCII byte per
character; more recently UTF-8 variable byte encodings which dramatically
complicates finding offsets but which gives efficient support for the
entire Unicode character space. In Haskell, the original text type,
'String', is implemented as a list of 'Char' which, because a Haskell list
is implemented as a /linked-list of boxed values/, is wildly inefficient at
any kind of scale.

In modern Haskell there are two primary ways to represent text.

First is via the [rather poorly named] 'ByteString' from the __bytestring__
package (which is an array of bytes in pinned memory). The
"Data.ByteString.Char8" submodule gives you ways to manipulate those arrays
as if they were ASCII characters. Confusingly there are both strict
(@Data.ByteString@) and lazy (@Data.ByteString.Lazy@) variants which are
often hard to tell the difference between when reading function signatures
or haddock documentation. The performance problem an immutable array backed
data type runs into is that appending a character (that is, ascii byte) or
concatonating a string (that is, another array of ascii bytes) is very
expensive and requires allocating a new larger array and copying the whole
thing into it. This led to the development of \"Builders\" which amortize
this reallocation cost over time, but it can be cumbersome to switch
between 'Builder', the lazy 'Data.ByteString.Lazy.ByteString' that results,
and then having to inevitably convert to a strict 'ByteString' because
that's what the next function in your sequence requires.

The second way is through the opaque 'Text' type of "Data.Text" from the
__text__ package, which is well tuned and high-performing but suffers from
the same design; it is likewise backed by arrays. Rather surprisingly, the
storage backing Text objects are encoded in UTF-16, meaning every time you
want to work with unicode characters that came in from /anywhere/ else and
which inevitably are UTF-8 encoded you have to convert to UTF-16 and copy
into a new array, wasting time and memory.

In this package we introduce 'Rope', a text type backed by the 2-3
'Data.FingerTree.FingerTree' data structure from the __fingertree__
package. This is not an uncommon solution in many languages as finger trees
support exceptionally efficient appending to either end and good
performance inserting anywhere else (you often find them as the backing
data type underneath text editors for this reason). Rather than 'Char' the
pieces of the rope are 'Data.Text.Short.ShortText' from the __text-short__
package, which are UTF-8 encoded and in normal memory managed by the
Haskell runtime. Conversion from other Haskell text types is not /O(1)/
(UTF-8 validity must be checked, or UTF-16 decoded, or...), but in our
benchmarking the performance has been comparable to the established types
and you may find the resultant interface for combining chunks is comparable
to using a Builder, without being forced to use a Builder.

'Rope' is used as the text type throughout this library. If you use the
functions within this package (rather than converting to other text types)
operations are very efficient. When you do need to convert to another type
you can use 'fromRope' or 'intoRope' from the 'Textual' typeclass.

Note that we haven't tried to cover the entire gamut of operations or
customary convenience functions you would find in the other libraries; so
far 'Rope' is concentrated on aiding interoperation, being good at
appending (lots of) small pieces, and then efficiently taking the resultant
text object out to a file handle, be that the terminal console, a file, or
a network socket.

-}
module Core.Text.Rope
    ( {-* Rope type -}
      Rope
    , unRope
    , width
    , contains
      {-* Interoperation and Output -}
    , Textual(..)
    , unsafeIntoRope
    , hOutput
      {-* Internals -}
    , Width(..)
    ) where

import Control.DeepSeq (NFData(..))
import qualified Data.ByteString as B (ByteString, unpack, empty, append)
import qualified Data.ByteString.Builder as B (Builder, toLazyByteString
    , hPutBuilder)
import qualified Data.ByteString.Lazy as L (toStrict)
import Data.String (IsString(..))
import qualified Data.FingerTree as F (FingerTree, Measured(..), empty
    , singleton, (><), (<|), (|>))
import Data.Foldable (foldr, foldr', foldMap, toList, any)
import qualified Data.Text as T (Text, empty, append)
import qualified Data.Text.Lazy as U (Text, fromChunks, foldrChunks
    , toStrict)
import qualified Data.Text.Lazy.Builder as U (Builder, toLazyText
    , fromText)
import qualified Data.Text.Short as S (ShortText, length, any
    , fromText, toText, fromByteString, toByteString, pack, unpack
    , concat, append, empty, toBuilder)
import qualified Data.Text.Short.Unsafe as S (fromByteStringUnsafe)
import Data.Hashable (Hashable, hashWithSalt, hashUsing)
import GHC.Generics (Generic)
import System.IO (Handle)

{-|
A type for textual data.

There are two use cases: first, referencing large blocks of data sourced from
external systems. Ideally we would hold onto this without copying the memory.
ByteString and its pinned memory is appropriate for this.

 ... maybe that's what Bytes is for

However, if we are manipulating this /at all/ in any way we're going to end 
up needing to copy it ... is that true?

Second use case is assembling text to go out. This involves considerable
appending of data, very very occaisionally inserting it. Often the pieces
are tiny.


-}

data Rope
    = Rope (F.FingerTree Width S.ShortText)
    deriving Generic

instance NFData Rope where
    rnf (Rope x) = foldMap (\piece -> rnf piece) x

instance Show Rope where
    show text = "\"" ++ fromRope text ++ "\""

instance Eq Rope where
    (==) (Rope x1) (Rope x2) = (==) (stream x1) (stream x2)
      where
        stream x = foldMap S.unpack x


{-|
Access the finger tree underlying the 'Rope'. You'll want the following
imports:

@
import qualified "Data.FingerTree" as F  -- from the __fingertree__ package
import qualified "Data.Text.Short" as S  -- from the __text-short__ package
@
-}
unRope :: Rope -> F.FingerTree Width S.ShortText
unRope (Rope x) = x
{-# INLINE unRope #-}


{-|
The length of the Rope, in characters. This is the monoid used to structure
the finger tree underlying the Rope.
-}
newtype Width = Width Int
    deriving (Eq, Ord, Show, Num, Generic)

instance F.Measured Width S.ShortText where
    measure :: S.ShortText -> Width
    measure piece = Width (S.length piece)

instance Semigroup Width where
    (<>) (Width w1) (Width w2) = Width (w1 + w2)

instance Monoid Width where
    mempty = Width 0
    mappend = (<>)

-- here Maybe we just need type Strand = ShortText and then Rope is
-- FingerTree Strand or Builder (Strand)

instance IsString Rope where
    fromString = Rope . F.singleton . S.pack

instance Semigroup Rope where
    (<>) (Rope x1) (Rope x2) = Rope ((F.><) x1 x2) -- god I hate these operators

instance Monoid Rope where
    mempty = Rope F.empty
    mappend = (<>)

width :: Rope -> Int
width = foldr' f 0 . unRope
  where
    f piece count = S.length piece + count

--
-- Manual instance to get around the fact that FingerTree doesn't have a
-- Hashable instance. If this were ever to become a hotspot we could
-- potentially use the Hashed caching type in the finger tree as
--
-- FingerTree Width (Hashed S.ShortText)
--
-- at the cost of endless unwrapping.
--
instance Hashable Rope where
    hashWithSalt salt (Rope x) = foldr f salt x
      where
        f :: S.ShortText -> Int -> Int
        f piece salt = hashWithSalt salt piece

{-|
Machinery to interpret a type as containing valid Unicode that can be
represented as a Rope object.

/Implementation notes/

Given that Rope is backed by a finger tree, 'append' is relatively
inexpensive, plus whatever the cost of conversion is. There is a subtle
trap, however: if adding small fragments of that were obtained by slicing
(for example) a large ByteString we would end up holding on to a reference
to the entire underlying block of memory. This module is optimized to
reduce heap fragmentation by letting the Haskell runtime and garbage
collector manage the memory, so instances are expected to /copy/ these
substrings out of pinned memory.

The ByteString instance requires that its content be valid UTF-8. If not an
empty Rope will be returned.

Several of the 'fromRope' implementations are expensive and involve a lot
of intermiate allocation and copying. If you're ultimately writing to a
handle prefer 'hOutput' which will write directly to the output buffer.
-}
class Textual a where
    {-|
Convert a Rope into another text-like type.
    -}
    fromRope :: Rope -> a
    {-|
Take another text-like type and convert it to a Rope.
    -}
    intoRope :: a -> Rope
    {-|
Append some text to this Rope. The default implementation is basically a
convenience wrapper around calling 'intoRope' and 'mappend'ing it to your
text (which will work just fine, but for some types more efficient
implementations are possible)t.
    -}
    append :: a -> Rope -> Rope
    append thing text = text <> intoRope thing

instance Textual (F.FingerTree Width S.ShortText) where
    fromRope = unRope
    intoRope = Rope

instance Textual Rope where
    fromRope = id
    intoRope = id

instance Textual S.ShortText where
    fromRope = foldr S.append S.empty . unRope
    intoRope = Rope . F.singleton
    append piece (Rope x) = Rope ((F.|>) x piece)

instance Textual T.Text where
    fromRope = U.toStrict . U.toLazyText . foldr f mempty . unRope
      where
        f :: S.ShortText -> U.Builder -> U.Builder
        f piece built = (<>) (U.fromText (S.toText piece)) built

    intoRope t = Rope (F.singleton (S.fromText t))
    append chunk (Rope x) = Rope ((F.|>) x (S.fromText chunk))

instance Textual U.Text where
    fromRope (Rope x) = U.fromChunks . fmap S.toText . toList $ x
    intoRope t = Rope (U.foldrChunks ((F.<|) . S.fromText) F.empty t)

instance Textual B.ByteString where
    fromRope = L.toStrict . B.toLazyByteString . foldr g mempty . unRope
      where
        g piece built = (<>) (S.toBuilder piece) built

    -- If the input ByteString does not contain valid UTF-8 then an empty
    -- Rope will be returned. That's not ideal.
    intoRope b' = case S.fromByteString b' of
        Just piece -> Rope (F.singleton piece)
        Nothing -> Rope F.empty         -- bad

    -- ditto
    append b' (Rope x) = case S.fromByteString b' of
        Just piece -> Rope ((F.|>) x piece)
        Nothing -> (Rope x)             -- bad

{-|
If you /know/ the input bytes are valid UTF-8 encoded characters, then
you can use this function to convert to a piece of Rope.
-}
unsafeIntoRope :: B.ByteString -> Rope
unsafeIntoRope = Rope . F.singleton . S.fromByteStringUnsafe

instance Textual [Char] where
    fromRope (Rope x) = foldr h [] x
      where
        h piece string = (S.unpack piece) ++ string -- ugh
    intoRope = Rope . F.singleton . S.pack

{-|
Write the 'Rope' to the given 'Handle'.

@
import "Core.Text"
import "Core.System" -- rexports stdout

main :: IO ()
main =
  let
    text :: 'Rope'
    text = "Hello World"
  in
    'hOutput' 'System.IO.stdout' text
@
because it's tradition.

Uses 'Data.ByteString.Builder.hPutBuilder' internally which saves all kinds
of intermediate allocation and copying because we can go from the
'Data.Text.Short.ShortText's in the finger tree to
'Data.ByteString.Short.ShortByteString' to
'Data.ByteString.Builder.Builder' to the 'System.IO.Handle''s output buffer
in one go.

-}

hOutput :: Handle -> Rope -> IO ()
hOutput handle (Rope x) = B.hPutBuilder handle (foldr j mempty x)
  where
    j piece built = (<>) (S.toBuilder piece) built

{-|
Does this Text contain this character?

We've used it to ask whether there are newlines present, for
example:

@
    if 'contains' '\n' text
        then handleComplexCase
        else keepItSimple
@
-}
contains :: Char -> Rope -> Bool
contains q (Rope x) = any j x
  where
    j piece = S.any (\c -> c == q) piece
