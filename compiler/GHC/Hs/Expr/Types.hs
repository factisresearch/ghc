{-# LANGUAGE CPP                       #-}
{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE DataKinds                 #-}
{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE StandaloneDeriving        #-}
{-# LANGUAGE TypeApplications          #-}
{-# LANGUAGE TypeFamilyDependencies    #-}
{-# LANGUAGE UndecidableInstances #-} -- Wrinkle in Note [Trees That Grow]
                                      -- in module GHC.Hs.Extension

{-# OPTIONS_GHC -Wno-incomplete-uni-patterns #-}

{-
(c) The University of Glasgow 2006
(c) The GRASP/AQUA Project, Glasgow University, 1992-1998
-}

-- | Abstract Haskell syntax for expressions.
module GHC.Hs.Expr.Types where

#include "HsVersions.h"

-- friends:
import GHC.Prelude

import GHC.Hs.Decls.Types
import GHC.Hs.Pat.Types
import GHC.Hs.Lit.Types
import GHC.Hs.Extension
import GHC.Hs.Type.Types
import GHC.Hs.Binds.Types

-- others:
import GHC.Tc.Types.Evidence
import GHC.Core
import GHC.Types.Name
import GHC.Types.Basic
import GHC.Types.Fixity
import GHC.Types.SourceText
import GHC.Types.SrcLoc
import GHC.Core.ConLike
import GHC.Unit.Module (ModuleName)
import GHC.Utils.Outputable
import GHC.Utils.Panic
import GHC.Data.FastString
import GHC.Core.Type

-- libraries:
import Data.Data hiding (Fixity(..))
import qualified Data.Data as Data (Fixity(..))

import GHCi.RemoteTypes ( ForeignRef )
import qualified Language.Haskell.TH as TH (Q)

{-
************************************************************************
*                                                                      *
\subsection{Expressions proper}
*                                                                      *
************************************************************************
-}

-- * Expressions proper

-- | Located Haskell Expression
type LHsExpr p = XRec p (HsExpr p)
  -- ^ May have 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnComma' when
  --   in a list

  -- For details on above see note [Api annotations] in GHC.Parser.Annotation

-------------------------
{- Note [NoSyntaxExpr]
~~~~~~~~~~~~~~~~~~~~~~
Syntax expressions can be missing (NoSyntaxExprRn or NoSyntaxExprTc)
for several reasons:

 1. As described in Note [Rebindable if]

 2. In order to suppress "not in scope: xyz" messages when a bit of
    rebindable syntax does not apply. For example, when using an irrefutable
    pattern in a BindStmt, we don't need a `fail` operator.

 3. Rebindable syntax might just not make sense. For example, a BodyStmt
    contains the syntax for `guard`, but that's used only in monad comprehensions.
    If we had more of a whiz-bang type system, we might be able to rule this
    case out statically.
-}

-- | Syntax Expression
--
-- SyntaxExpr is represents the function used in interpreting rebindable
-- syntax. In the parser, we have no information to supply; in the renamer,
-- we have the name of the function (but see
-- Note [Monad fail : Rebindable syntax, overloaded strings] for a wrinkle)
-- and in the type-checker we have a more elaborate structure 'SyntaxExprTc'.
--
-- In some contexts, rebindable syntax is not implemented, and so we have
-- constructors to represent that possibility in both the renamer and
-- typechecker instantiations.
--
-- E.g. @(>>=)@ is filled in before the renamer by the appropriate 'Name' for
--      @(>>=)@, and then instantiated by the type checker with its type args
--      etc
type family SyntaxExpr p

-- | Command Syntax Table (for Arrow syntax)
type CmdSyntaxTable p = [(Name, HsExpr p)]
-- See Note [CmdSyntaxTable]

{-
Note [CmdSyntaxTable]
~~~~~~~~~~~~~~~~~~~~~
Used only for arrow-syntax stuff (HsCmdTop), the CmdSyntaxTable keeps
track of the methods needed for a Cmd.

* Before the renamer, this list is an empty list

* After the renamer, it takes the form @[(std_name, HsVar actual_name)]@
  For example, for the 'arr' method
   * normal case:            (GHC.Control.Arrow.arr, HsVar GHC.Control.Arrow.arr)
   * with rebindable syntax: (GHC.Control.Arrow.arr, arr_22)
             where @arr_22@ is whatever 'arr' is in scope

* After the type checker, it takes the form [(std_name, <expression>)]
  where <expression> is the evidence for the method.  This evidence is
  instantiated with the class, but is still polymorphic in everything
  else.  For example, in the case of 'arr', the evidence has type
         forall b c. (b->c) -> a b c
  where 'a' is the ambient type of the arrow.  This polymorphism is
  important because the desugarer uses the same evidence at multiple
  different types.

This is Less Cool than what we normally do for rebindable syntax, which is to
make fully-instantiated piece of evidence at every use site.  The Cmd way
is Less Cool because
  * The renamer has to predict which methods are needed.
    See the tedious GHC.Rename.Expr.methodNamesCmd.

  * The desugarer has to know the polymorphic type of the instantiated
    method. This is checked by Inst.tcSyntaxName, but is less flexible
    than the rest of rebindable syntax, where the type is less
    pre-ordained.  (And this flexibility is useful; for example we can
    typecheck do-notation with (>>=) :: m1 a -> (a -> m2 b) -> m2 b.)
-}

-- | A Haskell expression.
data HsExpr p
  = HsVar     (XVar p)
              (LIdP p) -- ^ Variable
                       -- See Note [Located RdrNames]

  | HsUnboundVar (XUnboundVar p)
                 OccName     -- ^ Unbound variable; also used for "holes"
                             --   (_ or _x).
                             -- Turned from HsVar to HsUnboundVar by the
                             --   renamer, when it finds an out-of-scope
                             --   variable or hole.
                             -- The (XUnboundVar p) field becomes an HoleExprRef
                             --   after typechecking; this is where the
                             --   erroring expression will be written after
                             --   solving. See Note [Holes] in GHC.Tc.Types.Constraint.

  | HsConLikeOut (XConLikeOut p)
                 ConLike     -- ^ After typechecker only; must be different
                             -- HsVar for pretty printing

  | HsRecFld  (XRecFld p)
              (AmbiguousFieldOcc p) -- ^ Variable pointing to record selector
              -- The parser produces HsVars
              -- The renamer renames record-field selectors to HsRecFld
              -- The typechecker preserves HsRecFld

  | HsOverLabel (XOverLabel p)
                (Maybe (IdP p)) FastString
     -- ^ Overloaded label (Note [Overloaded labels] in GHC.OverloadedLabels)
     --   @Just id@ means @RebindableSyntax@ is in use, and gives the id of the
     --   in-scope 'fromLabel'.
     --   NB: Not in use after typechecking

  | HsIPVar   (XIPVar p)
              HsIPName   -- ^ Implicit parameter (not in use after typechecking)
  | HsOverLit (XOverLitE p)
              (HsOverLit p)  -- ^ Overloaded literals

  | HsLit     (XLitE p)
              (HsLit p)      -- ^ Simple (non-overloaded) literals

  | HsLam     (XLam p)
              (MatchGroup p (LHsExpr p))
                       -- ^ Lambda abstraction. Currently always a single match
       --
       -- - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnLam',
       --       'GHC.Parser.Annotation.AnnRarrow',

       -- For details on above see note [Api annotations] in GHC.Parser.Annotation

  | HsLamCase (XLamCase p) (MatchGroup p (LHsExpr p)) -- ^ Lambda-case
       --
       -- - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnLam',
       --           'GHC.Parser.Annotation.AnnCase','GHC.Parser.Annotation.AnnOpen',
       --           'GHC.Parser.Annotation.AnnClose'

       -- For details on above see note [Api annotations] in GHC.Parser.Annotation

  | HsApp     (XApp p) (LHsExpr p) (LHsExpr p) -- ^ Application

  | HsAppType (XAppTypeE p) -- After typechecking: the type argument
              (LHsExpr p)
              (LHsWcType (NoGhcTc p))  -- ^ Visible type application
       --
       -- Explicit type argument; e.g  f @Int x y
       -- NB: Has wildcards, but no implicit quantification
       --
       -- - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnAt',

  -- | Operator applications:
  -- NB Bracketed ops such as (+) come out as Vars.

  -- NB We need an expr for the operator in an OpApp/Section since
  -- the typechecker may need to apply the operator to a few types.

  | OpApp       (XOpApp p)
                (LHsExpr p)       -- left operand
                (LHsExpr p)       -- operator
                (LHsExpr p)       -- right operand

  -- | Negation operator. Contains the negated expression and the name
  -- of 'negate'
  --
  --  - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnMinus'

  -- For details on above see note [Api annotations] in GHC.Parser.Annotation
  | NegApp      (XNegApp p)
                (LHsExpr p)
                (SyntaxExpr p)

  -- | - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnOpen' @'('@,
  --             'GHC.Parser.Annotation.AnnClose' @')'@

  -- For details on above see note [Api annotations] in GHC.Parser.Annotation
  | HsPar       (XPar p)
                (LHsExpr p)  -- ^ Parenthesised expr; see Note [Parens in HsSyn]

  | SectionL    (XSectionL p)
                (LHsExpr p)    -- operand; see Note [Sections in HsSyn]
                (LHsExpr p)    -- operator
  | SectionR    (XSectionR p)
                (LHsExpr p)    -- operator; see Note [Sections in HsSyn]
                (LHsExpr p)    -- operand

  -- | Used for explicit tuples and sections thereof
  --
  --  - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnOpen',
  --         'GHC.Parser.Annotation.AnnClose'

  -- For details on above see note [Api annotations] in GHC.Parser.Annotation
  -- Note [ExplicitTuple]
  | ExplicitTuple
        (XExplicitTuple p)
        [LHsTupArg p]
        Boxity

  -- | Used for unboxed sum types
  --
  --  - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnOpen' @'(#'@,
  --          'GHC.Parser.Annotation.AnnVbar', 'GHC.Parser.Annotation.AnnClose' @'#)'@,
  --
  --  There will be multiple 'GHC.Parser.Annotation.AnnVbar', (1 - alternative) before
  --  the expression, (arity - alternative) after it
  | ExplicitSum
          (XExplicitSum p)
          ConTag --  Alternative (one-based)
          Arity  --  Sum arity
          (LHsExpr p)

  -- | - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnCase',
  --       'GHC.Parser.Annotation.AnnOf','GHC.Parser.Annotation.AnnOpen' @'{'@,
  --       'GHC.Parser.Annotation.AnnClose' @'}'@

  -- For details on above see note [Api annotations] in GHC.Parser.Annotation
  | HsCase      (XCase p)
                (LHsExpr p)
                (MatchGroup p (LHsExpr p))

  -- | - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnIf',
  --       'GHC.Parser.Annotation.AnnSemi',
  --       'GHC.Parser.Annotation.AnnThen','GHC.Parser.Annotation.AnnSemi',
  --       'GHC.Parser.Annotation.AnnElse',

  -- For details on above see note [Api annotations] in GHC.Parser.Annotation
  | HsIf        (XIf p)        -- GhcPs: this is a Bool; False <=> do not use
                               --  rebindable syntax
                (LHsExpr p)    --  predicate
                (LHsExpr p)    --  then part
                (LHsExpr p)    --  else part

  -- | Multi-way if
  --
  -- - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnIf'
  --       'GHC.Parser.Annotation.AnnOpen','GHC.Parser.Annotation.AnnClose',

  -- For details on above see note [Api annotations] in GHC.Parser.Annotation
  | HsMultiIf   (XMultiIf p) [LGRHS p (LHsExpr p)]

  -- | let(rec)
  --
  -- - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnLet',
  --       'GHC.Parser.Annotation.AnnOpen' @'{'@,
  --       'GHC.Parser.Annotation.AnnClose' @'}'@,'GHC.Parser.Annotation.AnnIn'

  -- For details on above see note [Api annotations] in GHC.Parser.Annotation
  | HsLet       (XLet p)
                (LHsLocalBinds p)
                (LHsExpr  p)

  -- | - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnDo',
  --             'GHC.Parser.Annotation.AnnOpen', 'GHC.Parser.Annotation.AnnSemi',
  --             'GHC.Parser.Annotation.AnnVbar',
  --             'GHC.Parser.Annotation.AnnClose'

  -- For details on above see note [Api annotations] in GHC.Parser.Annotation
  | HsDo        (XDo p)                  -- Type of the whole expression
                (HsStmtContext NoExtCon)
                -- The parameterisation of the above is unimportant
                -- because in this context we never use
                -- the PatGuard or ParStmt variant
                (XRec p [ExprLStmt p])   -- "do":one or more stmts

  -- | Syntactic list: [a,b,c,...]
  --
  --  - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnOpen' @'['@,
  --              'GHC.Parser.Annotation.AnnClose' @']'@

  -- For details on above see note [Api annotations] in GHC.Parser.Annotation
  -- See Note [Empty lists]
  | ExplicitList
                (XExplicitList p)  -- Gives type of components of list
                (Maybe (SyntaxExpr p))
                                   -- For OverloadedLists, the fromListN witness
                [LHsExpr p]

  -- | Record construction
  --
  --  - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnOpen' @'{'@,
  --         'GHC.Parser.Annotation.AnnDotdot','GHC.Parser.Annotation.AnnClose' @'}'@

  -- For details on above see note [Api annotations] in GHC.Parser.Annotation
  | RecordCon
      { rcon_ext      :: XRecordCon p
      , rcon_con_name :: LIdP p             -- The constructor name;
                                            --  not used after type checking
      , rcon_flds     :: HsRecordBinds p }  -- The fields

  -- | Record update
  --
  --  - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnOpen' @'{'@,
  --         'GHC.Parser.Annotation.AnnDotdot','GHC.Parser.Annotation.AnnClose' @'}'@

  -- For details on above see note [Api annotations] in GHC.Parser.Annotation
  | RecordUpd
      { rupd_ext  :: XRecordUpd p
      , rupd_expr :: LHsExpr p
      , rupd_flds :: [LHsRecUpdField p]
      }
  -- For a type family, the arg types are of the *instance* tycon,
  -- not the family tycon

  -- | Expression with an explicit type signature. @e :: type@
  --
  --  - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnDcolon'

  -- For details on above see note [Api annotations] in GHC.Parser.Annotation
  | ExprWithTySig
                (XExprWithTySig p)

                (LHsExpr p)
                (LHsSigWcType (NoGhcTc p))

  -- | Arithmetic sequence
  --
  --  - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnOpen' @'['@,
  --              'GHC.Parser.Annotation.AnnComma','GHC.Parser.Annotation.AnnDotdot',
  --              'GHC.Parser.Annotation.AnnClose' @']'@

  -- For details on above see note [Api annotations] in GHC.Parser.Annotation
  | ArithSeq
                (XArithSeq p)
                (Maybe (SyntaxExpr p))
                                  -- For OverloadedLists, the fromList witness
                (ArithSeqInfo p)

  -- For details on above see note [Api annotations] in GHC.Parser.Annotation

  -----------------------------------------------------------
  -- MetaHaskell Extensions

  -- | - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnOpen',
  --         'GHC.Parser.Annotation.AnnOpenE','GHC.Parser.Annotation.AnnOpenEQ',
  --         'GHC.Parser.Annotation.AnnClose','GHC.Parser.Annotation.AnnCloseQ'

  -- For details on above see note [Api annotations] in GHC.Parser.Annotation
  | HsBracket    (XBracket p) (HsBracket p)

    -- See Note [Pending Splices]
  | HsRnBracketOut
      (XRnBracketOut p)
      (HsBracket (HsBracketRn p)) -- Output of the renamer is the *original* renamed
                                  -- expression, plus
      [PendingRnSplice' p] -- _renamed_ splices to be type checked

  | HsTcBracketOut
      (XTcBracketOut p)
      (Maybe QuoteWrapper) -- The wrapper to apply type and dictionary argument
                           -- to the quote.
      (HsBracket (HsBracketRn p)) -- Output of the type checker is the *original*
                                 -- renamed expression, plus
      [PendingTcSplice' p] -- _typechecked_ splices to be
                           -- pasted back in by the desugarer

  -- | - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnOpen',
  --         'GHC.Parser.Annotation.AnnClose'

  -- For details on above see note [Api annotations] in GHC.Parser.Annotation
  | HsSpliceE  (XSpliceE p) (HsSplice p)

  -----------------------------------------------------------
  -- Arrow notation extension

  -- | @proc@ notation for Arrows
  --
  --  - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnProc',
  --          'GHC.Parser.Annotation.AnnRarrow'

  -- For details on above see note [Api annotations] in GHC.Parser.Annotation
  | HsProc      (XProc p)
                (LPat p)               -- arrow abstraction, proc
                (LHsCmdTop p)          -- body of the abstraction
                                       -- always has an empty stack

  ---------------------------------------
  -- static pointers extension
  -- | - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnStatic',

  -- For details on above see note [Api annotations] in GHC.Parser.Annotation
  | HsStatic (XStatic p) -- Free variables of the body
             (LHsExpr p)        -- Body

  ---------------------------------------
  -- Haskell program coverage (Hpc) Support

  | HsTick
     (XTick p)
     (Tickish (IdP p))
     (LHsExpr p)                       -- sub-expression

  | HsBinTick
     (XBinTick p)
     Int                                -- module-local tick number for True
     Int                                -- module-local tick number for False
     (LHsExpr p)                        -- sub-expression

  ---------------------------------------
  -- Expressions annotated with pragmas, written as {-# ... #-}
  | HsPragE (XPragE p) (HsPragE p) (LHsExpr p)

  | XExpr       !(XXExpr p)
  -- Note [Trees that Grow] extension constructor for the
  -- general idea, and Note [Rebindable syntax and HsExpansion]
  -- for an example of how we use it.

-- | The AST used to hard-refer to GhcPass, which was a layer violation. For now,
-- we paper it over with this new extension point.
type family HsBracketRn p
type family PendingRnSplice' p
type family PendingTcSplice' p

-- ---------------------------------------------------------------------

{-
Note [Rebindable syntax and HsExpansion]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

We implement rebindable syntax (RS) support by performing a desugaring
in the renamer. We transform GhcPs expressions affected by RS into the
appropriate desugared form, but **annotated with the original expression**.

Let us consider a piece of code like:

    {-# LANGUAGE RebindableSyntax #-}
    ifThenElse :: Char -> () -> () -> ()
    ifThenElse _ _ _ = ()
    x = if 'a' then () else True

The parsed AST for the RHS of x would look something like (slightly simplified):

    L locif (HsIf (L loca 'a') (L loctrue ()) (L locfalse True))

Upon seeing such an AST with RS on, we could transform it into a
mere function call, as per the RS rules, equivalent to the
following function application:

    ifThenElse 'a' () True

which doesn't typecheck. But GHC would report an error about
not being able to match the third argument's type (Bool) with the
expected type: (), in the expression _as desugared_, i.e in
the aforementioned function application. But the user never
wrote a function application! This would be pretty bad.

To remedy this, instead of transforming the original HsIf
node into mere applications of 'ifThenElse', we keep the
original 'if' expression around too, using the TTG
XExpr extension point to allow GHC to construct an
'HsExpansion' value that will keep track of the original
expression in its first field, and the desugared one in the
second field. The resulting renamed AST would look like:

    L locif (XExpr
      (HsExpanded
        (HsIf (L loca 'a')
              (L loctrue ())
              (L locfalse True)
        )
        (App (L generatedSrcSpan
                (App (L generatedSrcSpan
                        (App (L generatedSrcSpan (Var ifThenElse))
                             (L loca 'a')
                        )
                     )
                     (L loctrue ())
                )
             )
             (L locfalse True)
        )
      )
    )

When comes the time to typecheck the program, we end up calling
tcMonoExpr on the AST above. If this expression gives rise to
a type error, then it will appear in a context line and GHC
will pretty-print it using the 'Outputable (HsExpansion a b)'
instance defined below, which *only prints the original
expression*. This is the gist of the idea, but is not quite
enough to recover the error messages that we had with the
SyntaxExpr-based, typechecking/desugaring-to-core time
implementation of rebindable syntax. The key idea is to decorate
some elements of the desugared expression so as to be able to
give them a special treatment when typechecking the desugared
expression, to print a different context line or skip one
altogether.

Whenever we 'setSrcSpan' a 'generatedSrcSpan', we update a field in
TcLclEnv called 'tcl_in_gen_code', setting it to True, which indicates that we
entered generated code, i.e code fabricated by the compiler when rebinding some
syntax. If someone tries to push some error context line while that field is set
to True, the pushing won't actually happen and the context line is just dropped.
Once we 'setSrcSpan' a real span (for an expression that was in the original
source code), we set 'tcl_in_gen_code' back to False, indicating that we
"emerged from the generated code tunnel", and that the expressions we will be
processing are relevant to report in context lines again.

You might wonder why we store a RealSrcSpan in addition to a Bool in
the TcLclEnv: could we not store a Maybe RealSrcSpan? The problem is
that we still generate constraints when processing generated code,
and a CtLoc must contain a RealSrcSpan -- otherwise, error messages
might appear without source locations. So we keep the RealSrcSpan of
the last location spotted that wasn't generated; it's as good as
we're going to get in generated code. Once we get to sub-trees that
are not generated, then we update the RealSrcSpan appropriately, and
set the tcl_in_gen_code Bool to False.

---

A general recipe to follow this approach for new constructs could go as follows:

- Remove any GhcRn-time SyntaxExpr extensions to the relevant constructor for your
  construct, in HsExpr or related syntax data types.
- At renaming-time:
    - take your original node of interest (HsIf above)
    - rename its subexpressions (condition, true branch, false branch above)
    - construct the suitable "rebound"-and-renamed result (ifThenElse call
      above), where the 'SrcSpan' attached to any _fabricated node_ (the
      HsVar/HsApp nodes, above) is set to 'generatedSrcSpan'
    - take both the original node and that rebound-and-renamed result and wrap
      them in an XExpr: XExpr (HsExpanded <original node> <desugared>)
 - At typechecking-time:
    - remove any logic that was previously dealing with your rebindable
      construct, typically involving [tc]SyntaxOp, SyntaxExpr and friends.
    - the XExpr (HsExpanded ... ...) case in tcExpr already makes sure that we
      typecheck the desugared expression while reporting the original one in
      errors

-}

-- See Note [Rebindable syntax and HsExpansion] just above.
data HsExpansion a b
  = HsExpanded a b
  deriving Data

-- | Build a "wrapped" 'HsExpansion' out of an extension constructor,
--   and the two components of the expansion: original and desugared
--   expressions.
--
--   See Note [Rebindable Syntax and HsExpansion] above for more details.
mkExpanded
  :: (HsExpansion a b -> b) -- ^ XExpr, XCmd, ...
  -> a                      -- ^ source expression ('GhcPs')
  -> b                      -- ^ "desugared" expression
                            --   ('GhcRn')
  -> b                      -- ^ suitably wrapped
                            --   'HsExpansion'
mkExpanded xwrap a b = xwrap (HsExpanded a b)

-- | Just print the original expression (the @a@).
instance (Outputable a, Outputable b) => Outputable (HsExpansion a b) where
  ppr (HsExpanded a b) = ifPprDebug (vcat [ppr a, ppr b]) (ppr a)

-- ---------------------------------------------------------------------

-- | A pragma, written as {-# ... #-}, that may appear within an expression.
data HsPragE p
  = HsPragSCC   (XSCC p)
                SourceText            -- Note [Pragma source text] in GHC.Types.SourceText
                StringLiteral         -- "set cost centre" SCC pragma

  -- | - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnOpen',
  --       'GHC.Parser.Annotation.AnnOpen' @'{-\# GENERATED'@,
  --       'GHC.Parser.Annotation.AnnVal','GHC.Parser.Annotation.AnnVal',
  --       'GHC.Parser.Annotation.AnnColon','GHC.Parser.Annotation.AnnVal',
  --       'GHC.Parser.Annotation.AnnMinus',
  --       'GHC.Parser.Annotation.AnnVal','GHC.Parser.Annotation.AnnColon',
  --       'GHC.Parser.Annotation.AnnVal',
  --       'GHC.Parser.Annotation.AnnClose' @'\#-}'@

  | XHsPragE !(XXPragE p)

-- | Located Haskell Tuple Argument
--
-- 'HsTupArg' is used for tuple sections
-- @(,a,)@ is represented by
-- @ExplicitTuple [Missing ty1, Present a, Missing ty3]@
-- Which in turn stands for @(\x:ty1 \y:ty2. (x,a,y))@
type LHsTupArg id = XRec id (HsTupArg id)
-- | - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnComma'

-- For details on above see note [Api annotations] in GHC.Parser.Annotation

-- | Haskell Tuple Argument
data HsTupArg id
  = Present (XPresent id) (LHsExpr id)     -- ^ The argument
  | Missing (XMissing id)    -- ^ The argument is missing, but this is its type
  | XTupArg !(XXTupArg id)   -- ^ Note [Trees that Grow] extension point

{-
Note [Parens in HsSyn]
~~~~~~~~~~~~~~~~~~~~~~
HsPar (and ParPat in patterns, HsParTy in types) is used as follows

  * HsPar is required; the pretty printer does not add parens.

  * HsPars are respected when rearranging operator fixities.
    So   a * (b + c)  means what it says (where the parens are an HsPar)

  * For ParPat and HsParTy the pretty printer does add parens but this should be
    a no-op for ParsedSource, based on the pretty printer round trip feature
    introduced in
    https://phabricator.haskell.org/rGHC499e43824bda967546ebf95ee33ec1f84a114a7c

  * ParPat and HsParTy are pretty printed as '( .. )' regardless of whether or
    not they are strictly necessary. This should be addressed when #13238 is
    completed, to be treated the same as HsPar.


Note [Sections in HsSyn]
~~~~~~~~~~~~~~~~~~~~~~~~
Sections should always appear wrapped in an HsPar, thus
         HsPar (SectionR ...)
The parser parses sections in a wider variety of situations
(See Note [Parsing sections]), but the renamer checks for those
parens.  This invariant makes pretty-printing easier; we don't need
a special case for adding the parens round sections.

Note [Rebindable if]
~~~~~~~~~~~~~~~~~~~~
The rebindable syntax for 'if' is a bit special, because when
rebindable syntax is *off* we do not want to treat
   (if c then t else e)
as if it was an application (ifThenElse c t e).  Why not?
Because we allow an 'if' to return *unboxed* results, thus
  if blah then 3# else 4#
whereas that would not be possible using a all to a polymorphic function
(because you can't call a polymorphic function at an unboxed type).

So we use NoSyntaxExpr to mean "use the old built-in typing rule".

A further complication is that, in the `deriving` code, we never want
to use rebindable syntax. So, even in GhcPs, we want to denote whether
to use rebindable syntax or not. This is done via the type instance
for XIf GhcPs.

Note [Record Update HsWrapper]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
There is a wrapper in RecordUpd which is used for the *required*
constraints for pattern synonyms. This wrapper is created in the
typechecking and is then directly used in the desugaring without
modification.

For example, if we have the record pattern synonym P,
  pattern P :: (Show a) => a -> Maybe a
  pattern P{x} = Just x

  foo = (Just True) { x = False }
then `foo` desugars to something like
  foo = case Just True of
          P x -> P False
hence we need to provide the correct dictionaries to P's matcher on
the RHS so that we can build the expression.

Note [Located RdrNames]
~~~~~~~~~~~~~~~~~~~~~~~
A number of syntax elements have seemingly redundant locations attached to them.
This is deliberate, to allow transformations making use of the API Annotations
to easily correlate a Located Name in the RenamedSource with a Located RdrName
in the ParsedSource.

There are unfortunately enough differences between the ParsedSource and the
RenamedSource that the API Annotations cannot be used directly with
RenamedSource, so this allows a simple mapping to be used based on the location.

Note [ExplicitTuple]
~~~~~~~~~~~~~~~~~~~~
An ExplicitTuple is never just a data constructor like (,,,).
That is, the `[LHsTupArg p]` argument of `ExplicitTuple` has at least
one `Present` member (and is thus never empty).

A tuple data constructor like () or (,,,) is parsed as an `HsVar`, not an
`ExplicitTuple`, and stays that way. This is important for two reasons:

  1. We don't need -XTupleSections for (,,,)
  2. The type variables in (,,,) can be instantiated with visible type application.
     That is,

       (,,)     :: forall a b c. a -> b -> c -> (a,b,c)
       (True,,) :: forall {b} {c}. b -> c -> (Bool,b,c)

     Note that the tuple section has *inferred* arguments, while the data
     constructor has *specified* ones.
     (See Note [Required, Specified, and Inferred for types] in GHC.Tc.TyCl
     for background.)

Sadly, the grammar for this is actually ambiguous, and it's only thanks to the
preference of a shift in a shift/reduce conflict that the parser works as this
Note details. Search for a reference to this Note in GHC.Parser for further
explanation.

Note [Empty lists]
~~~~~~~~~~~~~~~~~~
An empty list could be considered either a data constructor (stored with
HsVar) or an ExplicitList. This Note describes how empty lists flow through the
various phases and why.

Parsing
-------
An empty list is parsed by the sysdcon nonterminal. It thus comes to life via
HsVar nilDataCon (defined in GHC.Builtin.Types). A freshly-parsed (HsExpr GhcPs) empty list
is never a ExplicitList.

Renaming
--------
If -XOverloadedLists is enabled, we must type-check the empty list as if it
were a call to fromListN. (This is true regardless of the setting of
-XRebindableSyntax.) This is very easy if the empty list is an ExplicitList,
but an annoying special case if it's an HsVar. So the renamer changes a
HsVar nilDataCon to an ExplicitList [], but only if -XOverloadedLists is on.
(Why not always? Read on, dear friend.) This happens in the HsVar case of rnExpr.

Type-checking
-------------
We want to accept an expression like [] @Int. To do this, we must infer that
[] :: forall a. [a]. This is easy if [] is a HsVar with the right DataCon inside.
However, the type-checking for explicit lists works differently: [x,y,z] is never
polymorphic. Instead, we unify the types of x, y, and z together, and use the
unified type as the argument to the cons and nil constructors. Thus, treating
[] as an empty ExplicitList in the type-checker would prevent [] @Int from working.

However, if -XOverloadedLists is on, then [] @Int really shouldn't be allowed:
it's just like fromListN 0 [] @Int. Since
  fromListN :: forall list. IsList list => Int -> [Item list] -> list
that expression really should be rejected. Thus, the renamer's behaviour is
exactly what we want: treat [] as a datacon when -XNoOverloadedLists, and as
an empty ExplicitList when -XOverloadedLists.

See also #13680, which requested [] @Int to work.
-}

-----------------------
isQuietHsExpr :: HsExpr id -> Bool
-- Parentheses do display something, but it gives little info and
-- if we go deeper when we go inside them then we get ugly things
-- like (...)
isQuietHsExpr (HsPar {})        = True
-- applications don't display anything themselves
isQuietHsExpr (HsApp {})        = True
isQuietHsExpr (HsAppType {})    = True
isQuietHsExpr (OpApp {})        = True
isQuietHsExpr _ = False

-----------------------
pprExternalSrcLoc :: (StringLiteral,(Int,Int),(Int,Int)) -> SDoc
pprExternalSrcLoc (StringLiteral _ src,(n1,n2),(n3,n4))
  = ppr (src,(n1,n2),(n3,n4))

{-
HsSyn records exactly where the user put parens, with HsPar.
So generally speaking we print without adding any parens.
However, some code is internally generated, and in some places
parens are absolutely required; so for these places we use
pprParendLExpr (but don't print double parens of course).

For operator applications we don't add parens, because the operator
fixities should do the job, except in debug mode (-dppr-debug) so we
can see the structure of the parse tree.
-}

{-
************************************************************************
*                                                                      *
\subsection{Commands (in arrow abstractions)}
*                                                                      *
************************************************************************

We re-use HsExpr to represent these.
-}

-- | Located Haskell Command (for arrow syntax)
type LHsCmd id = XRec id (HsCmd id)

-- | Haskell Command (e.g. a "statement" in an Arrow proc block)
data HsCmd id
  -- | - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.Annlarrowtail',
  --          'GHC.Parser.Annotation.Annrarrowtail','GHC.Parser.Annotation.AnnLarrowtail',
  --          'GHC.Parser.Annotation.AnnRarrowtail'

  -- For details on above see note [Api annotations] in GHC.Parser.Annotation
  = HsCmdArrApp          -- Arrow tail, or arrow application (f -< arg)
        (XCmdArrApp id)  -- type of the arrow expressions f,
                         -- of the form a t t', where arg :: t
        (LHsExpr id)     -- arrow expression, f
        (LHsExpr id)     -- input expression, arg
        HsArrAppType     -- higher-order (-<<) or first-order (-<)
        Bool             -- True => right-to-left (f -< arg)
                         -- False => left-to-right (arg >- f)

  -- | - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnOpenB' @'(|'@,
  --         'GHC.Parser.Annotation.AnnCloseB' @'|)'@

  -- For details on above see note [Api annotations] in GHC.Parser.Annotation
  | HsCmdArrForm         -- Command formation,  (| e cmd1 .. cmdn |)
        (XCmdArrForm id)
        (LHsExpr id)     -- The operator.
                         -- After type-checking, a type abstraction to be
                         -- applied to the type of the local environment tuple
        LexicalFixity    -- Whether the operator appeared prefix or infix when
                         -- parsed.
        (Maybe Fixity)   -- fixity (filled in by the renamer), for forms that
                         -- were converted from OpApp's by the renamer
        [LHsCmdTop id]   -- argument commands

  | HsCmdApp    (XCmdApp id)
                (LHsCmd id)
                (LHsExpr id)

  | HsCmdLam    (XCmdLam id)
                (MatchGroup id (LHsCmd id))     -- kappa
       -- ^ - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnLam',
       --       'GHC.Parser.Annotation.AnnRarrow',

       -- For details on above see note [Api annotations] in GHC.Parser.Annotation

  | HsCmdPar    (XCmdPar id)
                (LHsCmd id)                     -- parenthesised command
    -- ^ - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnOpen' @'('@,
    --             'GHC.Parser.Annotation.AnnClose' @')'@

    -- For details on above see note [Api annotations] in GHC.Parser.Annotation

  | HsCmdCase   (XCmdCase id)
                (LHsExpr id)
                (MatchGroup id (LHsCmd id))     -- bodies are HsCmd's
    -- ^ - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnCase',
    --       'GHC.Parser.Annotation.AnnOf','GHC.Parser.Annotation.AnnOpen' @'{'@,
    --       'GHC.Parser.Annotation.AnnClose' @'}'@

    -- For details on above see note [Api annotations] in GHC.Parser.Annotation

  | HsCmdLamCase (XCmdLamCase id)
                 (MatchGroup id (LHsCmd id))    -- bodies are HsCmd's
    -- ^ - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnLam',
    --       'GHC.Parser.Annotation.AnnCase','GHC.Parser.Annotation.AnnOpen' @'{'@,
    --       'GHC.Parser.Annotation.AnnClose' @'}'@

    -- For details on above see note [Api annotations] in GHC.Parser.Annotation

  | HsCmdIf     (XCmdIf id)
                (SyntaxExpr id)         -- cond function
                (LHsExpr id)            -- predicate
                (LHsCmd id)             -- then part
                (LHsCmd id)             -- else part
    -- ^ - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnIf',
    --       'GHC.Parser.Annotation.AnnSemi',
    --       'GHC.Parser.Annotation.AnnThen','GHC.Parser.Annotation.AnnSemi',
    --       'GHC.Parser.Annotation.AnnElse',

    -- For details on above see note [Api annotations] in GHC.Parser.Annotation

  | HsCmdLet    (XCmdLet id)
                (LHsLocalBinds id)      -- let(rec)
                (LHsCmd  id)
    -- ^ - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnLet',
    --       'GHC.Parser.Annotation.AnnOpen' @'{'@,
    --       'GHC.Parser.Annotation.AnnClose' @'}'@,'GHC.Parser.Annotation.AnnIn'

    -- For details on above see note [Api annotations] in GHC.Parser.Annotation

  | HsCmdDo     (XCmdDo id)                     -- Type of the whole expression
                (XRec id [CmdLStmt id])
    -- ^ - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnDo',
    --             'GHC.Parser.Annotation.AnnOpen', 'GHC.Parser.Annotation.AnnSemi',
    --             'GHC.Parser.Annotation.AnnVbar',
    --             'GHC.Parser.Annotation.AnnClose'

    -- For details on above see note [Api annotations] in GHC.Parser.Annotation

  | XCmd        !(XXCmd id)     -- Note [Trees that Grow] extension point


-- | Haskell Array Application Type
data HsArrAppType = HsHigherOrderApp | HsFirstOrderApp
  deriving Data


{- | Top-level command, introducing a new arrow.
This may occur inside a proc (where the stack is empty) or as an
argument of a command-forming operator.
-}

-- | Located Haskell Top-level Command
type LHsCmdTop p = XRec p (HsCmdTop p)

-- | Haskell Top-level Command
data HsCmdTop p
  = HsCmdTop (XCmdTop p)
             (LHsCmd p)
  | XCmdTop !(XXCmdTop p)        -- Note [Trees that Grow] extension point

-----------------------
isQuietHsCmd :: HsCmd id -> Bool
-- Parentheses do display something, but it gives little info and
-- if we go deeper when we go inside them then we get ugly things
-- like (...)
isQuietHsCmd (HsCmdPar {}) = True
-- applications don't display anything themselves
isQuietHsCmd (HsCmdApp {}) = True
isQuietHsCmd _ = False

{-
************************************************************************
*                                                                      *
\subsection{Record binds}
*                                                                      *
************************************************************************
-}

-- | Haskell Record Bindings
type HsRecordBinds p = HsRecFields p (LHsExpr p)

{-
************************************************************************
*                                                                      *
\subsection{@Match@, @GRHSs@, and @GRHS@ datatypes}
*                                                                      *
************************************************************************

@Match@es are sets of pattern bindings and right hand sides for
functions, patterns or case branches. For example, if a function @g@
is defined as:
\begin{verbatim}
g (x,y) = y
g ((x:ys),y) = y+1,
\end{verbatim}
then \tr{g} has two @Match@es: @(x,y) = y@ and @((x:ys),y) = y+1@.

It is always the case that each element of an @[Match]@ list has the
same number of @pats@s inside it.  This corresponds to saying that
a function defined by pattern matching must have the same number of
patterns in each equation.
-}

data MatchGroup p body
  = MG { mg_ext     :: XMG p body -- Post-typechecker, types of args and result
       , mg_alts    :: XRec p [LMatch p body]  -- The alternatives
       , mg_origin  :: Origin }
     -- The type is the type of the entire group
     --      t1 -> ... -> tn -> tr
     -- where there are n patterns
  | XMatchGroup !(XXMatchGroup p body)

data MatchGroupTc
  = MatchGroupTc
       { mg_arg_tys :: [Scaled Type]  -- Types of the arguments, t1..tn
       , mg_res_ty  :: Type    -- Type of the result, tr
       } deriving Data

-- | Located Match
type LMatch id body = XRec id (Match id body)
-- ^ May have 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnSemi' when in a
--   list

-- For details on above see note [Api annotations] in GHC.Parser.Annotation
data Match p body
  = Match {
        m_ext :: XCMatch p body,
        m_ctxt :: HsMatchContext (NoGhcTc p),
          -- See note [m_ctxt in Match]
        m_pats :: [LPat p], -- The patterns
        m_grhss :: (GRHSs p body)
  }
  | XMatch !(XXMatch p body)

{-
Note [m_ctxt in Match]
~~~~~~~~~~~~~~~~~~~~~~

A Match can occur in a number of contexts, such as a FunBind, HsCase, HsLam and
so on.

In order to simplify tooling processing and pretty print output, the provenance
is captured in an HsMatchContext.

This is particularly important for the API Annotations for a multi-equation
FunBind.

The parser initially creates a FunBind with a single Match in it for
every function definition it sees.

These are then grouped together by getMonoBind into a single FunBind,
where all the Matches are combined.

In the process, all the original FunBind fun_id's bar one are
discarded, including the locations.

This causes a problem for source to source conversions via API
Annotations, so the original fun_ids and infix flags are preserved in
the Match, when it originates from a FunBind.

Example infix function definition requiring individual API Annotations

    (&&&  ) [] [] =  []
    xs    &&&   [] =  xs
    (  &&&  ) [] ys =  ys



-}


isInfixMatch :: Match id body -> Bool
isInfixMatch match = case m_ctxt match of
  FunRhs {mc_fixity = Infix} -> True
  _                          -> False

-- | Guarded Right-Hand Sides
--
-- GRHSs are used both for pattern bindings and for Matches
--
--  - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnVbar',
--        'GHC.Parser.Annotation.AnnEqual','GHC.Parser.Annotation.AnnWhere',
--        'GHC.Parser.Annotation.AnnOpen','GHC.Parser.Annotation.AnnClose'
--        'GHC.Parser.Annotation.AnnRarrow','GHC.Parser.Annotation.AnnSemi'

-- For details on above see note [Api annotations] in GHC.Parser.Annotation
data GRHSs p body
  = GRHSs {
      grhssExt :: XCGRHSs p body,
      grhssGRHSs :: [LGRHS p body],      -- ^ Guarded RHSs
      grhssLocalBinds :: LHsLocalBinds p -- ^ The where clause
    }
  | XGRHSs !(XXGRHSs p body)

-- | Located Guarded Right-Hand Side
type LGRHS id body = XRec id (GRHS id body)

-- | Guarded Right Hand Side.
data GRHS p body = GRHS (XCGRHS p body)
                        [GuardLStmt p] -- Guards
                        body           -- Right hand side
                  | XGRHS !(XXGRHS p body)

-- We know the list must have at least one @Match@ in it.

pp_rhs :: Outputable body => HsMatchContext passL -> body -> SDoc
pp_rhs ctxt rhs = matchSeparator ctxt <+> pprDeeper (ppr rhs)

{-
************************************************************************
*                                                                      *
\subsection{Do stmts and list comprehensions}
*                                                                      *
************************************************************************
-}

-- | Located @do@ block Statement
type LStmt id body = XRec id (StmtLR id id body)

-- | Located Statement with separate Left and Right id's
type LStmtLR idL idR body = XRec idL (StmtLR idL idR body)

-- | @do@ block Statement
type Stmt id body = StmtLR id id body

-- | Command Located Statement
type CmdLStmt   id = LStmt id (LHsCmd  id)

-- | Command Statement
type CmdStmt    id = Stmt  id (LHsCmd  id)

-- | Expression Located Statement
type ExprLStmt  id = LStmt id (LHsExpr id)

-- | Expression Statement
type ExprStmt   id = Stmt  id (LHsExpr id)

-- | Guard Located Statement
type GuardLStmt id = LStmt id (LHsExpr id)

-- | Guard Statement
type GuardStmt  id = Stmt  id (LHsExpr id)

-- | Ghci Located Statement
type GhciLStmt  id = LStmt id (LHsExpr id)

-- | Ghci Statement
type GhciStmt   id = Stmt  id (LHsExpr id)

-- The SyntaxExprs in here are used *only* for do-notation and monad
-- comprehensions, which have rebindable syntax. Otherwise they are unused.
-- | API Annotations when in qualifier lists or guards
--  - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnVbar',
--         'GHC.Parser.Annotation.AnnComma','GHC.Parser.Annotation.AnnThen',
--         'GHC.Parser.Annotation.AnnBy','GHC.Parser.Annotation.AnnBy',
--         'GHC.Parser.Annotation.AnnGroup','GHC.Parser.Annotation.AnnUsing'

-- For details on above see note [Api annotations] in GHC.Parser.Annotation
data StmtLR idL idR body -- body should always be (LHs**** idR)
  = LastStmt  -- Always the last Stmt in ListComp, MonadComp,
              -- and (after the renamer, see GHC.Rename.Expr.checkLastStmt) DoExpr, MDoExpr
              -- Not used for GhciStmtCtxt, PatGuard, which scope over other stuff
          (XLastStmt idL idR body)
          body
          (Maybe Bool)  -- Whether return was stripped
            -- Just True <=> return with a dollar was stripped by ApplicativeDo
            -- Just False <=> return without a dollar was stripped by ApplicativeDo
            -- Nothing <=> Nothing was stripped
          (SyntaxExpr idR)   -- The return operator
            -- The return operator is used only for MonadComp
            -- For ListComp we use the baked-in 'return'
            -- For DoExpr, MDoExpr, we don't apply a 'return' at all
            -- See Note [Monad Comprehensions]
            -- - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnLarrow'

  -- For details on above see note [Api annotations] in GHC.Parser.Annotation
  | BindStmt (XBindStmt idL idR body)
             -- ^ Post renaming has optional fail and bind / (>>=) operator.
             -- Post typechecking, also has multiplicity of the argument
             -- and the result type of the function passed to bind;
             -- that is, (P, S) in (>>=) :: Q -> (R # P -> S) -> T
             -- See Note [The type of bind in Stmts]
             (LPat idL)
             body

  -- | 'ApplicativeStmt' represents an applicative expression built with
  -- '<$>' and '<*>'.  It is generated by the renamer, and is desugared into the
  -- appropriate applicative expression by the desugarer, but it is intended
  -- to be invisible in error messages.
  --
  -- For full details, see Note [ApplicativeDo] in "GHC.Rename.Expr"
  --
  | ApplicativeStmt
             (XApplicativeStmt idL idR body) -- Post typecheck, Type of the body
             [ ( SyntaxExpr idR
               , ApplicativeArg idL) ]
                      -- [(<$>, e1), (<*>, e2), ..., (<*>, en)]
             (Maybe (SyntaxExpr idR))  -- 'join', if necessary

  | BodyStmt (XBodyStmt idL idR body) -- Post typecheck, element type
                                      -- of the RHS (used for arrows)
             body              -- See Note [BodyStmt]
             (SyntaxExpr idR)  -- The (>>) operator
             (SyntaxExpr idR)  -- The `guard` operator; used only in MonadComp
                               -- See notes [Monad Comprehensions]

  -- | - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnLet'
  --          'GHC.Parser.Annotation.AnnOpen' @'{'@,'GHC.Parser.Annotation.AnnClose' @'}'@,

  -- For details on above see note [Api annotations] in GHC.Parser.Annotation
  | LetStmt  (XLetStmt idL idR body) (LHsLocalBindsLR idL idR)

  -- ParStmts only occur in a list/monad comprehension
  | ParStmt  (XParStmt idL idR body)    -- Post typecheck,
                                        -- S in (>>=) :: Q -> (R -> S) -> T
             [ParStmtBlock idL idR]
             (HsExpr idR)               -- Polymorphic `mzip` for monad comprehensions
             (SyntaxExpr idR)           -- The `>>=` operator
                                        -- See notes [Monad Comprehensions]
            -- After renaming, the ids are the binders
            -- bound by the stmts and used after themp

  | TransStmt {
      trS_ext   :: XTransStmt idL idR body, -- Post typecheck,
                                            -- R in (>>=) :: Q -> (R -> S) -> T
      trS_form  :: TransForm,
      trS_stmts :: [ExprLStmt idL],   -- Stmts to the *left* of the 'group'
                                      -- which generates the tuples to be grouped

      trS_bndrs :: [(IdP idR, IdP idR)], -- See Note [TransStmt binder map]

      trS_using :: LHsExpr idR,
      trS_by :: Maybe (LHsExpr idR),  -- "by e" (optional)
        -- Invariant: if trS_form = GroupBy, then grp_by = Just e

      trS_ret :: SyntaxExpr idR,      -- The monomorphic 'return' function for
                                      -- the inner monad comprehensions
      trS_bind :: SyntaxExpr idR,     -- The '(>>=)' operator
      trS_fmap :: HsExpr idR          -- The polymorphic 'fmap' function for desugaring
                                      -- Only for 'group' forms
                                      -- Just a simple HsExpr, because it's
                                      -- too polymorphic for tcSyntaxOp
    }                                 -- See Note [Monad Comprehensions]

  -- Recursive statement (see Note [How RecStmt works] below)
  -- | - 'GHC.Parser.Annotation.AnnKeywordId' : 'GHC.Parser.Annotation.AnnRec'

  -- For details on above see note [Api annotations] in GHC.Parser.Annotation
  | RecStmt
     { recS_ext :: XRecStmt idL idR body
     , recS_stmts :: [LStmtLR idL idR body]

        -- The next two fields are only valid after renaming
     , recS_later_ids :: [IdP idR]
                         -- The ids are a subset of the variables bound by the
                         -- stmts that are used in stmts that follow the RecStmt

     , recS_rec_ids :: [IdP idR]
                         -- Ditto, but these variables are the "recursive" ones,
                         -- that are used before they are bound in the stmts of
                         -- the RecStmt.
        -- An Id can be in both groups
        -- Both sets of Ids are (now) treated monomorphically
        -- See Note [How RecStmt works] for why they are separate

        -- Rebindable syntax
     , recS_bind_fn :: SyntaxExpr idR -- The bind function
     , recS_ret_fn  :: SyntaxExpr idR -- The return function
     , recS_mfix_fn :: SyntaxExpr idR -- The mfix function
      }
  | XStmtLR !(XXStmtLR idL idR body)

data TransForm   -- The 'f' below is the 'using' function, 'e' is the by function
  = ThenForm     -- then f               or    then f by e             (depending on trS_by)
  | GroupForm    -- then group using f   or    then group by e using f (depending on trS_by)
  deriving Data

-- | Parenthesised Statement Block
data ParStmtBlock idL idR
  = ParStmtBlock
        (XParStmtBlock idL idR)
        [ExprLStmt idL]
        [IdP idR]          -- The variables to be returned
        (SyntaxExpr idR)   -- The return operator
  | XParStmtBlock !(XXParStmtBlock idL idR)

-- | The fail operator
--
-- This is used for `.. <-` "bind statments" in do notation, including
-- non-monadic "binds" in applicative.
--
-- The fail operator is 'Just expr' if it potentially fail monadically. if the
-- pattern match cannot fail, or shouldn't fail monadically (regular incomplete
-- pattern exception), it is 'Nothing'.
--
-- See Note [Monad fail : Rebindable syntax, overloaded strings] for the type of
-- expression in the 'Just' case, and why it is so.
--
-- See Note [Failing pattern matches in Stmts] for which contexts for
-- '@BindStmt@'s should use the monadic fail and which shouldn't.
type FailOperator id = Maybe (SyntaxExpr id)

-- | Applicative Argument
data ApplicativeArg idL
  = ApplicativeArgOne      -- A single statement (BindStmt or BodyStmt)
    { xarg_app_arg_one  :: XApplicativeArgOne idL
      -- ^ The fail operator, after renaming
      --
      -- The fail operator is needed if this is a BindStmt
      -- where the pattern can fail. E.g.:
      -- (Just a) <- stmt
      -- The fail operator will be invoked if the pattern
      -- match fails.
      -- It is also used for guards in MonadComprehensions.
      -- The fail operator is Nothing
      -- if the pattern match can't fail
    , app_arg_pattern   :: LPat idL -- WildPat if it was a BodyStmt (see below)
    , arg_expr          :: LHsExpr idL
    , is_body_stmt      :: Bool
      -- ^ True <=> was a BodyStmt,
      -- False <=> was a BindStmt.
      -- See Note [Applicative BodyStmt]
    }
  | ApplicativeArgMany     -- do { stmts; return vars }
    { xarg_app_arg_many :: XApplicativeArgMany idL
    , app_stmts         :: [ExprLStmt idL] -- stmts
    , final_expr        :: HsExpr idL    -- return (v1,..,vn), or just (v1,..,vn)
    , bv_pattern        :: LPat idL      -- (v1,...,vn)
    , stmt_context      :: HsStmtContext NoExtCon -- context of the do expression
                                                  -- used in pprArg
    }
  | XApplicativeArg !(XXApplicativeArg idL)

{-
Note [The type of bind in Stmts]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Some Stmts, notably BindStmt, keep the (>>=) bind operator.
We do NOT assume that it has type
    (>>=) :: m a -> (a -> m b) -> m b
In some cases (see #303, #1537) it might have a more
exotic type, such as
    (>>=) :: m i j a -> (a -> m j k b) -> m i k b
So we must be careful not to make assumptions about the type.
In particular, the monad may not be uniform throughout.

Note [TransStmt binder map]
~~~~~~~~~~~~~~~~~~~~~~~~~~~
The [(idR,idR)] in a TransStmt behaves as follows:

  * Before renaming: []

  * After renaming:
          [ (x27,x27), ..., (z35,z35) ]
    These are the variables
       bound by the stmts to the left of the 'group'
       and used either in the 'by' clause,
                or     in the stmts following the 'group'
    Each item is a pair of identical variables.

  * After typechecking:
          [ (x27:Int, x27:[Int]), ..., (z35:Bool, z35:[Bool]) ]
    Each pair has the same unique, but different *types*.

Note [BodyStmt]
~~~~~~~~~~~~~~~
BodyStmts are a bit tricky, because what they mean
depends on the context.  Consider the following contexts:

        A do expression of type (m res_ty)
        ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
        * BodyStmt E any_ty:   do { ....; E; ... }
                E :: m any_ty
          Translation: E >> ...

        A list comprehensions of type [elt_ty]
        ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
        * BodyStmt E Bool:   [ .. | .... E ]
                        [ .. | ..., E, ... ]
                        [ .. | .... | ..., E | ... ]
                E :: Bool
          Translation: if E then fail else ...

        A guard list, guarding a RHS of type rhs_ty
        ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
        * BodyStmt E BooParStmtBlockl:   f x | ..., E, ... = ...rhs...
                E :: Bool
          Translation: if E then fail else ...

        A monad comprehension of type (m res_ty)
        ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
        * BodyStmt E Bool:   [ .. | .... E ]
                E :: Bool
          Translation: guard E >> ...

Array comprehensions are handled like list comprehensions.

Note [How RecStmt works]
~~~~~~~~~~~~~~~~~~~~~~~~
Example:
   HsDo [ BindStmt x ex

        , RecStmt { recS_rec_ids   = [a, c]
                  , recS_stmts     = [ BindStmt b (return (a,c))
                                     , LetStmt a = ...b...
                                     , BindStmt c ec ]
                  , recS_later_ids = [a, b]

        , return (a b) ]

Here, the RecStmt binds a,b,c; but
  - Only a,b are used in the stmts *following* the RecStmt,
  - Only a,c are used in the stmts *inside* the RecStmt
        *before* their bindings

Why do we need *both* rec_ids and later_ids?  For monads they could be
combined into a single set of variables, but not for arrows.  That
follows from the types of the respective feedback operators:

        mfix :: MonadFix m => (a -> m a) -> m a
        loop :: ArrowLoop a => a (b,d) (c,d) -> a b c

* For mfix, the 'a' covers the union of the later_ids and the rec_ids
* For 'loop', 'c' is the later_ids and 'd' is the rec_ids

Note [Typing a RecStmt]
~~~~~~~~~~~~~~~~~~~~~~~
A (RecStmt stmts) types as if you had written

  (v1,..,vn, _, ..., _) <- mfix (\~(_, ..., _, r1, ..., rm) ->
                                 do { stmts
                                    ; return (v1,..vn, r1, ..., rm) })

where v1..vn are the later_ids
      r1..rm are the rec_ids

Note [Monad Comprehensions]
~~~~~~~~~~~~~~~~~~~~~~~~~~~
Monad comprehensions require separate functions like 'return' and
'>>=' for desugaring. These functions are stored in the statements
used in monad comprehensions. For example, the 'return' of the 'LastStmt'
expression is used to lift the body of the monad comprehension:

  [ body | stmts ]
   =>
  stmts >>= \bndrs -> return body

In transform and grouping statements ('then ..' and 'then group ..') the
'return' function is required for nested monad comprehensions, for example:

  [ body | stmts, then f, rest ]
   =>
  f [ env | stmts ] >>= \bndrs -> [ body | rest ]

BodyStmts require the 'Control.Monad.guard' function for boolean
expressions:

  [ body | exp, stmts ]
   =>
  guard exp >> [ body | stmts ]

Parallel statements require the 'Control.Monad.Zip.mzip' function:

  [ body | stmts1 | stmts2 | .. ]
   =>
  mzip stmts1 (mzip stmts2 (..)) >>= \(bndrs1, (bndrs2, ..)) -> return body

In any other context than 'MonadComp', the fields for most of these
'SyntaxExpr's stay bottom.


Note [Applicative BodyStmt]

(#12143) For the purposes of ApplicativeDo, we treat any BodyStmt
as if it was a BindStmt with a wildcard pattern.  For example,

  do
    x <- A
    B
    return x

is transformed as if it were

  do
    x <- A
    _ <- B
    return x

so it transforms to

  (\(x,_) -> x) <$> A <*> B

But we have to remember when we treat a BodyStmt like a BindStmt,
because in error messages we want to emit the original syntax the user
wrote, not our internal representation.  So ApplicativeArgOne has a
Bool flag that is True when the original statement was a BodyStmt, so
that we can pretty-print it correctly.
-}

pprBindStmt :: (Outputable pat, Outputable expr) => pat -> expr -> SDoc
pprBindStmt pat expr = hsep [ppr pat, larrow, ppr expr]

pprTransStmt :: Outputable body => Maybe body -> body -> TransForm -> SDoc
pprTransStmt by using ThenForm
  = sep [ text "then", nest 2 (ppr using), nest 2 (pprBy by)]
pprTransStmt by using GroupForm
  = sep [ text "then group", nest 2 (pprBy by), nest 2 (ptext (sLit "using") <+> ppr using)]

pprBy :: Outputable body => Maybe body -> SDoc
pprBy Nothing  = empty
pprBy (Just e) = text "by" <+> ppr e

ppr_module_name_prefix :: Maybe ModuleName -> SDoc
ppr_module_name_prefix = \case
  Nothing -> empty
  Just module_name -> ppr module_name <> char '.'

{-
************************************************************************
*                                                                      *
                Template Haskell quotation brackets
*                                                                      *
************************************************************************
-}

-- | Haskell Splice
data HsSplice id
   = HsTypedSplice       --  $$z  or $$(f 4)
        (XTypedSplice id)
        SpliceDecoration -- Whether $$( ) variant found, for pretty printing
        (IdP id)         -- A unique name to identify this splice point
        (LHsExpr id)     -- See Note [Pending Splices]

   | HsUntypedSplice     --  $z  or $(f 4)
        (XUntypedSplice id)
        SpliceDecoration -- Whether $( ) variant found, for pretty printing
        (IdP id)         -- A unique name to identify this splice point
        (LHsExpr id)     -- See Note [Pending Splices]

   | HsQuasiQuote        -- See Note [Quasi-quote overview] in GHC.Tc.Gen.Splice
        (XQuasiQuote id)
        (IdP id)         -- Splice point
        (IdP id)         -- Quoter
        SrcSpan          -- The span of the enclosed string
        FastString       -- The enclosed string

   -- AZ:TODO: use XSplice instead of HsSpliced
   | HsSpliced  -- See Note [Delaying modFinalizers in untyped splices] in
                -- GHC.Rename.Splice.
                -- This is the result of splicing a splice. It is produced by
                -- the renamer and consumed by the typechecker. It lives only
                -- between the two.
        (XSpliced id)
        ThModFinalizers     -- TH finalizers produced by the splice.
        (HsSplicedThing id) -- The result of splicing
   | XSplice !(XXSplice id) -- Note [Trees that Grow] extension point

-- | A splice can appear with various decorations wrapped around it. This data
-- type captures explicitly how it was originally written, for use in the pretty
-- printer.
data SpliceDecoration
  = DollarSplice  -- ^ $splice or $$splice
  | BareSplice    -- ^ bare splice
  deriving (Data, Eq, Show)

instance Outputable SpliceDecoration where
  ppr x = text $ show x


isTypedSplice :: HsSplice id -> Bool
isTypedSplice (HsTypedSplice {}) = True
isTypedSplice _                  = False   -- Quasi-quotes are untyped splices

-- | Finalizers produced by a splice with
-- 'Language.Haskell.TH.Syntax.addModFinalizer'
--
-- See Note [Delaying modFinalizers in untyped splices] in GHC.Rename.Splice. For how
-- this is used.
--
newtype ThModFinalizers = ThModFinalizers [ForeignRef (TH.Q ())]

-- A Data instance which ignores the argument of 'ThModFinalizers'.
instance Data ThModFinalizers where
  gunfold _ z _ = z $ ThModFinalizers []
  toConstr  a   = mkConstr (dataTypeOf a) "ThModFinalizers" [] Data.Prefix
  dataTypeOf a  = mkDataType "HsExpr.ThModFinalizers" [toConstr a]

-- | Haskell Spliced Thing
--
-- Values that can result from running a splice.
data HsSplicedThing id
    = HsSplicedExpr (HsExpr id) -- ^ Haskell Spliced Expression
    | HsSplicedTy   (HsType id) -- ^ Haskell Spliced Type
    | HsSplicedPat  (Pat id)    -- ^ Haskell Spliced Pattern


-- See Note [Pending Splices]
type SplicePointName = Name

data UntypedSpliceFlavour
  = UntypedExpSplice
  | UntypedPatSplice
  | UntypedTypeSplice
  | UntypedDeclSplice
  deriving Data

ppr_quasi :: OutputableBndr p => p -> p -> FastString -> SDoc
ppr_quasi n quoter quote = whenPprDebug (brackets (ppr n)) <>
                           char '[' <> ppr quoter <> vbar <>
                           ppr quote <> text "|]"

-- | Haskell Bracket
data HsBracket p
  = ExpBr  (XExpBr p)   (LHsExpr p)    -- [|  expr  |]
  | PatBr  (XPatBr p)   (LPat p)      -- [p| pat   |]
  | DecBrL (XDecBrL p)  [LHsDecl p]   -- [d| decls |]; result of parser
  | DecBrG (XDecBrG p)  (HsGroup p)   -- [d| decls |]; result of renamer
  | TypBr  (XTypBr p)   (LHsType p)   -- [t| type  |]
  | VarBr  (XVarBr p)   Bool (IdP p)  -- True: 'x, False: ''T
                                -- (The Bool flag is used only in pprHsBracket)
  | TExpBr (XTExpBr p) (LHsExpr p)    -- [||  expr  ||]
  | XBracket !(XXBracket p)           -- Note [Trees that Grow] extension point

isTypedBracket :: HsBracket id -> Bool
isTypedBracket (TExpBr {}) = True
isTypedBracket _           = False

thBrackets :: SDoc -> SDoc -> SDoc
thBrackets pp_kind pp_body = char '[' <> pp_kind <> vbar <+>
                             pp_body <+> text "|]"

thTyBrackets :: SDoc -> SDoc
thTyBrackets pp_body = text "[||" <+> pp_body <+> ptext (sLit "||]")

{-
************************************************************************
*                                                                      *
\subsection{Enumerations and list comprehensions}
*                                                                      *
************************************************************************
-}

-- | Arithmetic Sequence Information
data ArithSeqInfo id
  = From            (LHsExpr id)
  | FromThen        (LHsExpr id)
                    (LHsExpr id)
  | FromTo          (LHsExpr id)
                    (LHsExpr id)
  | FromThenTo      (LHsExpr id)
                    (LHsExpr id)
                    (LHsExpr id)
-- AZ: Should ArithSeqInfo have a TTG extension?

pp_dotdot :: SDoc
pp_dotdot = text " .. "

{-
************************************************************************
*                                                                      *
\subsection{HsMatchCtxt}
*                                                                      *
************************************************************************
-}

-- | Haskell Match Context
--
-- Context of a pattern match. This is more subtle than it would seem. See Note
-- [Varieties of pattern matches].
data HsMatchContext p
  = FunRhs { mc_fun        :: LIdP p    -- ^ function binder of @f@
           , mc_fixity     :: LexicalFixity -- ^ fixing of @f@
           , mc_strictness :: SrcStrictness -- ^ was @f@ banged?
                                            -- See Note [FunBind vs PatBind]
           }
                                -- ^A pattern matching on an argument of a
                                -- function binding
  | LambdaExpr                  -- ^Patterns of a lambda
  | CaseAlt                     -- ^Patterns and guards on a case alternative
  | IfAlt                       -- ^Guards of a multi-way if alternative
  | ProcExpr                    -- ^Patterns of a proc
  | PatBindRhs                  -- ^A pattern binding  eg [y] <- e = e
  | PatBindGuards               -- ^Guards of pattern bindings, e.g.,
                                --    (Just b) | Just _ <- x = e
                                --             | otherwise   = e'

  | RecUpd                      -- ^Record update [used only in GHC.HsToCore.Expr to
                                --    tell matchWrapper what sort of
                                --    runtime error message to generate]

  | StmtCtxt (HsStmtContext p)  -- ^Pattern of a do-stmt, list comprehension,
                                -- pattern guard, etc

  | ThPatSplice            -- ^A Template Haskell pattern splice
  | ThPatQuote             -- ^A Template Haskell pattern quotation [p| (a,b) |]
  | PatSyn                 -- ^A pattern synonym declaration

isPatSynCtxt :: HsMatchContext p -> Bool
isPatSynCtxt ctxt =
  case ctxt of
    PatSyn -> True
    _      -> False

-- | Haskell Statement Context.
data HsStmtContext p
  = ListComp
  | MonadComp

  | DoExpr (Maybe ModuleName)        -- ^[ModuleName.]do { ... }
  | MDoExpr (Maybe ModuleName)       -- ^[ModuleName.]mdo { ... }  ie recursive do-expression
  | ArrowExpr                        -- ^do-notation in an arrow-command context

  | GhciStmtCtxt                     -- ^A command-line Stmt in GHCi pat <- rhs
  | PatGuard (HsMatchContext p)      -- ^Pattern guard for specified thing
  | ParStmtCtxt (HsStmtContext p)    -- ^A branch of a parallel stmt
  | TransStmtCtxt (HsStmtContext p)  -- ^A branch of a transform stmt

qualifiedDoModuleName_maybe :: HsStmtContext p -> Maybe ModuleName
qualifiedDoModuleName_maybe ctxt = case ctxt of
  DoExpr m -> m
  MDoExpr m -> m
  _ -> Nothing

isComprehensionContext :: HsStmtContext id -> Bool
-- Uses comprehension syntax [ e | quals ]
isComprehensionContext ListComp          = True
isComprehensionContext MonadComp         = True
isComprehensionContext (ParStmtCtxt c)   = isComprehensionContext c
isComprehensionContext (TransStmtCtxt c) = isComprehensionContext c
isComprehensionContext _ = False

-- | Is this a monadic context?
isMonadStmtContext :: HsStmtContext id -> Bool
isMonadStmtContext MonadComp            = True
isMonadStmtContext DoExpr{}             = True
isMonadStmtContext MDoExpr{}            = True
isMonadStmtContext GhciStmtCtxt         = True
isMonadStmtContext (ParStmtCtxt ctxt)   = isMonadStmtContext ctxt
isMonadStmtContext (TransStmtCtxt ctxt) = isMonadStmtContext ctxt
isMonadStmtContext _ = False -- ListComp, PatGuard, ArrowExpr

isMonadCompContext :: HsStmtContext id -> Bool
isMonadCompContext MonadComp = True
isMonadCompContext _         = False

matchSeparator :: HsMatchContext p -> SDoc
matchSeparator (FunRhs {})   = text "="
matchSeparator CaseAlt       = text "->"
matchSeparator IfAlt         = text "->"
matchSeparator LambdaExpr    = text "->"
matchSeparator ProcExpr      = text "->"
matchSeparator PatBindRhs    = text "="
matchSeparator PatBindGuards = text "="
matchSeparator (StmtCtxt _)  = text "<-"
matchSeparator RecUpd        = text "=" -- This can be printed by the pattern
                                       -- match checker trace
matchSeparator ThPatSplice  = panic "unused"
matchSeparator ThPatQuote   = panic "unused"
matchSeparator PatSyn       = panic "unused"

pprMatchContext :: (Outputable (IdP p), UnXRec p)
                => HsMatchContext p -> SDoc
pprMatchContext ctxt
  | want_an ctxt = text "an" <+> pprMatchContextNoun ctxt
  | otherwise    = text "a"  <+> pprMatchContextNoun ctxt
  where
    want_an (FunRhs {}) = True  -- Use "an" in front
    want_an ProcExpr    = True
    want_an _           = False

pprMatchContextNoun :: forall p. (Outputable (IdP p), UnXRec p)
                    => HsMatchContext p -> SDoc
pprMatchContextNoun (FunRhs {mc_fun=fun})
                                    = text "equation for"
                                      <+> quotes (ppr (unXRec @p fun))
pprMatchContextNoun CaseAlt         = text "case alternative"
pprMatchContextNoun IfAlt           = text "multi-way if alternative"
pprMatchContextNoun RecUpd          = text "record-update construct"
pprMatchContextNoun ThPatSplice     = text "Template Haskell pattern splice"
pprMatchContextNoun ThPatQuote      = text "Template Haskell pattern quotation"
pprMatchContextNoun PatBindRhs      = text "pattern binding"
pprMatchContextNoun PatBindGuards   = text "pattern binding guards"
pprMatchContextNoun LambdaExpr      = text "lambda abstraction"
pprMatchContextNoun ProcExpr        = text "arrow abstraction"
pprMatchContextNoun (StmtCtxt ctxt) = text "pattern binding in"
                                      $$ pprAStmtContext ctxt
pprMatchContextNoun PatSyn          = text "pattern synonym declaration"

-----------------
pprAStmtContext, pprStmtContext :: (Outputable (IdP p), UnXRec p)
                                => HsStmtContext p -> SDoc
pprAStmtContext ctxt = article <+> pprStmtContext ctxt
  where
    pp_an = text "an"
    pp_a  = text "a"
    article = case ctxt of
                  MDoExpr Nothing -> pp_an
                  GhciStmtCtxt  -> pp_an
                  _             -> pp_a


-----------------
pprStmtContext GhciStmtCtxt    = text "interactive GHCi command"
pprStmtContext (DoExpr m)      = prependQualified m (text "'do' block")
pprStmtContext (MDoExpr m)     = prependQualified m (text "'mdo' block")
pprStmtContext ArrowExpr       = text "'do' block in an arrow command"
pprStmtContext ListComp        = text "list comprehension"
pprStmtContext MonadComp       = text "monad comprehension"
pprStmtContext (PatGuard ctxt) = text "pattern guard for" $$ pprMatchContext ctxt

-- Drop the inner contexts when reporting errors, else we get
--     Unexpected transform statement
--     in a transformed branch of
--          transformed branch of
--          transformed branch of monad comprehension
pprStmtContext (ParStmtCtxt c) =
  ifPprDebug (sep [text "parallel branch of", pprAStmtContext c])
             (pprStmtContext c)
pprStmtContext (TransStmtCtxt c) =
  ifPprDebug (sep [text "transformed branch of", pprAStmtContext c])
             (pprStmtContext c)

prependQualified :: Maybe ModuleName -> SDoc -> SDoc
prependQualified Nothing  t = t
prependQualified (Just _) t = text "qualified" <+> t
