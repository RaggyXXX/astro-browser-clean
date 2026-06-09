# Selector Compatibility

## Basic Selectors

| Selector | Status | Notes |
| --- | --- | --- |
| Type, class, id, universal | supported | Core parser/matcher paths. |
| Attribute existence and operators | supported | `[attr]`, `=`, `~=`, `|=`, `^=`, `$=`, `*=` plus case flag subset. |
| Descendant, child, adjacent, general sibling combinators | supported | Practical selector matching. |
| Selector lists | supported | Top-level comma splitting with function-depth awareness. |

## Functional Selectors

| Selector | Status | Notes |
| --- | --- | --- |
| `:is()` | supported | Max specificity handling. |
| `:where()` | supported | Zero-specificity behavior represented. |
| `:not()` | supported | Selector-list arguments and max specificity behavior. |
| `:has()` | supported | Descendant, child, adjacent, and sibling V1 selector paths have regression coverage; very large trees should still be used carefully. |
| `:nth-child`, `:nth-last-child`, `:nth-of-type`, `:nth-last-of-type` | supported | `an+b`, odd/even, fixed index. |

## State Pseudo-Classes

| Selector | Status | Notes |
| --- | --- | --- |
| `:hover`, `:focus`, `:active`, `:focus-visible`, `:focus-within` | supported | Runtime pseudo state. |
| `:checked`, `:disabled`, `:enabled` | supported | Component/form state path. |
| `:link`, `:visited` | supported | Runtime visited registry path; browser privacy restrictions are not modeled. |
| `:required`, `:optional`, `:valid`, `:invalid` | supported | V1 component validation-state subset. |
| `:placeholder-shown`, `:read-only`, `:read-write` | supported | V1 form-control selector subset. |

## Structural Pseudo-Classes

| Selector | Status | Notes |
| --- | --- | --- |
| `:first-child`, `:last-child`, `:only-child` | supported | DOM sibling paths. |
| `:first-of-type`, `:last-of-type`, `:only-of-type` | supported | Type sibling paths. |
| `:empty`, `:root` | supported | Runtime node tree semantics. |
| `:lang()`, `:dir()` | supported | Attribute/ancestor-based subset. |

## Pseudo-Elements

| Selector | Status | Notes |
| --- | --- | --- |
| `::before`, `::after` | partial | Synthetic content nodes; not full browser generated-content parity. |
| `::placeholder` | supported | Input/textarea placeholder styling subset. |
| `::selection` | supported | Selection paint subset. |
| `::marker` | supported | List marker paint subset. |
| `::first-letter`, `::first-line` | supported | Typography paint path is implemented. |
| Browser-native pseudo-elements beyond above | planned | Add only when a component/use case needs them. |



