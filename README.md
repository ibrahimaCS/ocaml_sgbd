# OCaml Mini-RDBMS — Functional Dependencies & Normalization

> A pure-functional relational database engine written from scratch in OCaml, that automatically discovers functional dependencies from data and computes the normal form (1NF / 2NF / 3NF) of any table.

[![OCaml](https://img.shields.io/badge/OCaml-4.13+-orange.svg)](https://ocaml.org/)
[![Build](https://img.shields.io/badge/build-make-blue.svg)]()
[![Status](https://img.shields.io/badge/status-complete-success.svg)]()

---

## Table of contents

1. [What this project does](#what-this-project-does)
2. [Why a database engine in OCaml?](#why-a-database-engine-in-ocaml)
3. [The strict functional constraints](#the-strict-functional-constraints)
4. [Project layout](#project-layout)
5. [Build and run](#build-and-run)
6. [The data model](#the-data-model)
7. [Part I — Relational algebra](#part-i--relational-algebra)
8. [Part II — Normalisation analyser](#part-ii--normalisation-analyser)
9. [Validation tests and reference results](#validation-tests-and-reference-results)
10. [Complexity analysis](#complexity-analysis)
11. [Important to know](#Important-to-know)

---

## What this project does

This is a **small relational database management system (RDBMS) in pure OCaml**, implementing:

- The five core operators of relational algebra: `check_table`, `insert`, `prod`, `projection`, `restrict`.
- An **automatic normal-form analyser** that, given the data already present in a table:
  1. discovers every valid functional dependency `X → Y` between subsets of columns;
  2. filters out the trivial, redundant and non-minimal ones to keep only *elementary* dependencies;
  3. identifies all candidate keys;
  4. determines whether the table is in **1NF**, **2NF** or **3NF**, and reports the highest level reached.

The engine works **purely from the data**: there is no user-declared schema constraint. The dependencies and keys are *induced* by the actual rows, exactly as a real DBA would have to do during reverse-engineering of an undocumented database.

> **Real-world framing (per the project brief):** *"The Natural Strategic School for Innovative and Strange Investigations wishes to commission the development of a system for verifying the normal-form level of its database, as part of the preparation for replacing its schooling software."*

---

## Why a database engine in OCaml?

OCaml is a statically-typed, functional-first language widely used in research (Inria), industry (Jane Street, Facebook's Infer), and theorem provers (Coq). It is the language of choice at ENSIIE for the first-semester programming course because it forces a very rigorous style:

- **No `null` by default.** A column can hold `VNull` only if explicitly declared nullable.
- **Algebraic data types and exhaustive pattern matching.** The compiler refuses to typecheck a `match` that doesn't cover every case.
- **Immutable data structures.** Tables are values, not mutable handles. Every operation returns a new table.
- **First-class functions.** Predicates passed to `restrict` are just `row -> bool` functions.

In other words: the language guarantees, at compile time, what real-world databases enforce with manuals and code reviews.

---

## The strict functional constraints

In line with the course requirements, **every list traversal in this project is written using only `List.map`, `List.fold_left` and `List.fold_right`**. The following idioms are *forbidden* throughout the codebase:

| forbidden                   | rationale                                     | what I used instead                                |
|-----------------------------|-----------------------------------------------|----------------------------------------------------|
| `List.filter`               | hidden recursion                              | `fold_left` with a conditional accumulator         |
| `List.mem`                  | hidden recursion                              | a small `appartient` helper built from `fold_left` |
| `List.iter`                 | side-effectful traversal                      | `fold_left` with `()` accumulator                  |
| `List.exists`, `List.for_all` | hidden recursion                            | reimplemented from `fold_left` with a bool accumulator |
| `option` types              | not yet introduced in the course              | sentinel values + `failwith` for errors            |
| `when` guards               | not yet introduced                            | explicit `if … then … else`                        |
| pattern guards              | not yet introduced                            | nested matches                                     |

The basic list utilities that were unavailable (`for_all`, `rev`, `filter`, `appartient`, `est_inclus`, `est_inclus_strict`, `sous_listes`) are **all reimplemented at the top of `projet.ml`** exclusively from `List.fold_left` and `List.map`. This made the complexity analysis (section below) self-contained: every cost claim can be derived from a direct call graph rather than relying on an opaque standard-library implementation.

---

## Project layout

```
.
├── Makefile         # build, run, toplevel, clean targets
├── README.md
├── .gitignore
├── projet.ml        # the engine: types, helpers, relational algebra, normaliser
└── tests.ml         # reference tables and assertions
```

Two files only — that's the entire project. `projet.ml` is ~480 lines, `tests.ml` is ~320 lines, both heavily commented in English with `@requires` / `@ensures` ACSL-style contracts on every public function.

---

## Build and run

### Build (Makefile)

The Makefile collapses `projet.ml` and `tests.ml` into a single OCaml source file (`_build/all.ml`) — the `#use "projet.ml"` directive at the top of `tests.ml` is only understood by the toplevel, so we strip it for the compiler.

```bash
make            # builds the test executable (bytecode)
make run        # builds then runs the tests
make toplevel   # opens an interactive OCaml toplevel with projet.ml loaded
make clean      # removes every build artifact
```

### Direct toplevel use

If you prefer the toplevel:

```bash
ocaml
# then in the toplevel:
#use "tests.ml";;
```

---
## The data model

> ℹ️ **Imposed by the course brief, not authored.** The seven types below are *given* in the project specification and identical across every student's submission. They appear here only to make the rest of the README readable.

The project manipulates a deliberately minimal relational model:

| type        | role                                                                 |
|-------------|----------------------------------------------------------------------|
| `dbtype`    | a column's primitive type — `TInt` or `TText`                        |
| `coltype`   | a pair `(dbtype, nullable?)` describing a column                     |
| `dbvalue`   | a single cell — `VInt`, `VText` or `VNull`                           |
| `schema`    | an ordered list of `(name, coltype)` pairs                           |
| `row`       | an ordered list of `dbvalue`s                                        |
| `table`     | a record `{ cols : schema ; rows : row list }`                       |
| `fd`        | a functional dependency `(string list) × (string list)` ≡ `X → Y`    |

Notice what is **not** in this model: indexes, primary keys, foreign keys, transactions, joins beyond the cartesian product. The whole point of the exercise is to *infer* the structural information (candidate keys, functional dependencies, normal form) **from the raw data alone**, without any user-declared constraint.

A representative table — the `produit` table used in the validation tests below — has the shape:

## Part I — Relational algebra

Five operators, each implemented from first principles and validated against hand-built test tables.

### 1. `check_table : table -> bool`

Validates a table by checking three invariants in sequence:

1. **Column-name uniqueness.** No two columns share a name. The schema is walked once, accumulating names already seen; if the final accumulator differs in length from the schema, the table is rejected.
2. **Dimensional coherence.** Every row has exactly `|cols|` values.
3. **Type and nullability compatibility.** For every `(value, column)` pair: a `VInt` only appears in a `TInt` column, a `VText` only in a `TText` column, and `VNull` only where the column's nullable flag is `true`.

A single `fold_left` over the row-schema pair handles all three checks per row.

### 2. `insert : table -> row -> table`

Adds a row to an existing table with a **double safety check**: `check_table` is called *before* the insertion (rejects invalid sources) and *after* (rejects an inserted row that violates type/nullability rules). Both checks are required: the post-check on its own would not catch a malformed source table.

The implementation appends via `tbl.rows @ [row]` (`O(R)` due to OCaml list concatenation). Cons-insertion (`row :: tbl.rows`) would be `O(1)` but reverses the order, which would break the row-ordering invariant used by the tests.

### 3. `prod : table -> table -> table`

Cartesian product of two tables.

```
T₁ : n₁ rows                T₂ : n₂ rows
                    ⟶   T₁ × T₂ : n₁ · n₂ rows
List.fold_left + List.map
```

Implementation: a `fold_left` over `T₁` nesting a `map` over `T₂`. For each row `r₁ ∈ T₁`, we generate the list of all concatenations `r₁ | r₂` for `r₂ ∈ T₂`. The new schema is the concatenation of both schemas. Both tables are pre-validated by `check_table`.

### 4. `projection : table -> string list -> table`

Project a table onto a subset of columns. Built from three internal helpers:

- `check_field_exists : string -> schema -> bool` — confirms a column exists.
- `get_col_info : string -> schema -> coltype` — extracts the `(dbtype, nullable)` pair for a named column. Raises `Failure "Champ absent"` if missing.
- `get_val_from_row : string -> schema -> row -> dbvalue` — extracts the value at the given column. Returns `(value, residual_row, found)` so the caller can detect failure without exceptions.

The projection itself maps `get_val_from_row` over the list of requested fields for every row.

### 5. `restrict : table -> (row -> bool) -> table`

Keep rows that satisfy a predicate. The schema is preserved unchanged; the implementation delegates to the home-grown `filter` (which is itself a `fold_left`).

---

## Part II — Normalisation analyser

This is the heart of the project, and the part with the most algorithmic substance.

### Definitions

**Functional dependency.** Given a relation `R(A₁, …, Aₙ)` and two subsets `X, Y ⊆ Cols(R)`, we say `X → Y` (read: *X determines Y*) if for every two tuples `r₁, r₂ ∈ R`,
```
r₁[X] = r₂[X]   ⟹   r₁[Y] = r₂[Y]
```

**Elementary dependency.** `X → A` is *elementary* if (i) `|A| = 1`, (ii) `A ∉ X`, (iii) there is no strict subset `X' ⊊ X` with `X' → A`.

**Candidate key.** `X ⊆ Cols` is a candidate key if (i) `X → Cols` (superkey property), and (ii) no strict subset of `X` is also a superkey (minimality).

**Normal forms.**

| Form | Definition                                                                                       |
|:----:|--------------------------------------------------------------------------------------------------|
| 1NF  | Every attribute holds an atomic (monovalued, non-composite) value.                               |
| 2NF  | 1NF + every non-key attribute is functionally dependent on the *whole* of every candidate key.   |
| 3NF  | 2NF + every elementary FD `X → A` has `X` a candidate key **or** `A` part of some candidate key. |

### Algorithm pipeline

```
                  ┌──────────────────────────────────────────────┐
                  │   compute_deps :   all valid FDs (X, Y)      │
                  │   – generates P(Cols) × P(Cols),             │
                  │     keeps only the FDs that hold in tbl       │
                  └──────────────┬───────────────────────────────┘
                                 │
                                 ▼
                  ┌──────────────────────────────────────────────┐
                  │ compute_elementary_deps :                    │
                  │   keep (X, {a})  with  a ∉ X                 │
                  │   and no X' ⊊ X giving X' → {a}              │
                  └──────────────┬───────────────────────────────┘
                                 │
                                 ▼
                  ┌──────────────────────────────────────────────┐
                  │ Candidate keys :                             │
                  │   list all X ⊆ Cols with                     │
                  │   X → Cols and no Y ⊊ X also superkey        │
                  └──────────────┬───────────────────────────────┘
                                 │
                                 ▼
                  ┌──────────────────────────────────────────────┐
                  │ For every elementary FD :                    │
                  │   try respecte_3NF                           │
                  │   else try respecte_2NF                      │
                  │   else default 1NF                           │
                  └──────────────────────────────────────────────┘
```

### Six core functions

| function                     | purpose                                                                            |
|------------------------------|------------------------------------------------------------------------------------|
| `sous_listes`                | generates `P(L)` (every subset) by structural induction with `fold_left`           |
| `verify_df`                  | checks `X → Y`                                                                     |
| `compute_deps`               | exhaustively enumerates valid FDs over `P(Cols) × P(Cols)`                         |
| `compute_elementary_deps`    | filters `compute_deps` down to elementary FDs                                      |
| `est_cle_candidate`          | superkey + minimality test                                                          |
| `respecte_2NF` / `respecte_3NF` | per-FD validation using the conditions C₁, C₂, C₃ from the course notes        |
| `normalization_level`        | top-level dispatcher: returns `1`, `2` or `3`                                      |

#### The 2NF test, in detail

For an elementary FD `X → {a}`, the table satisfies 2NF *at this dependency* if **at least one** of:

- **(C₁)** `X` is itself a candidate key, or
- **(C₂)** `{a}` is part of some candidate key, or
- **(C₃)** `X` contains an attribute that belongs to *no* candidate key.

A table is in 2NF iff every elementary FD passes one of these three conditions.

#### The 3NF test, in detail

For an elementary FD `X → {a}`, the table satisfies 3NF *at this dependency* if **at least one** of:

- **(C₁)** `X` is a candidate key, or
- **(C₂)** `{a}` is part of some candidate key.

(3NF is strictly stronger than 2NF, since `C₃` is dropped.)

---

## Validation tests and reference results

Three reference tables — one per normal-form level — exercise the full pipeline.

### Test 1 — Table `produit` (expected: 3NF)

| n_produit | libelle | prix |
|:---------:|:-------:|:----:|
|    P1     | stylo   |  2   |
|    P2     | cahier  |  3   |
|    P3     | regle   |  1   |

`compute_elementary_deps` returns the six FDs:

```
{n_produit} → libelle      {libelle}   → n_produit
{n_produit} → prix         {libelle}   → prix
{prix}      → n_produit    {prix}      → libelle
```

Every attribute, taken alone, determines the other two — a consequence of the three columns being pairwise in bijection on the current data. The algorithm therefore identifies **three candidate keys**: `{n_produit}`, `{libelle}`, `{prix}`.

**3NF test:** every left-hand side of an elementary FD is itself a candidate key — condition C₁ is satisfied throughout. The table is in **3NF**.

### Test 2 — Table `commande` (expected: 2NF)

| n_comm | n_produit | qtte | type |
|:------:|:---------:|:----:|:----:|
|  C01   |    P1     |  3   |  A   |
|  C02   |    P1     |  5   |  A   |
|  C03   |    P2     |  1   |  B   |
|  C04   |    P2     |  1   |  B   |
|  C05   |    P3     |  3   |  A   |

`compute_elementary_deps` returns five FDs:

```
{n_comm}    → n_produit       {n_produit} → type
{n_comm}    → qtte            {qtte}      → type
{n_comm}    → type
```

There is **one** candidate key: `{n_comm}`.

**3NF test:** `{n_produit} → type` and `{qtte} → type` fail both C₁ (neither LHS is a candidate key) and C₂ (`type` isn't in any candidate key). 3NF is **violated**.

**2NF test:** for the two offending FDs, `n_produit`, `qtte` and `type` all belong to *no* candidate key — condition C₃ rescues them. The table is in **2NF**.

### Test 3 — Table `inscription` (expected: 1NF)

| n_etudiant |    ue    | nom_etudiant |
|:----------:|:--------:|:------------:|
|    E1      | INPF12   | Alice        |
|    E1      | LAOB12   | Alice        |
|    E2      | INPF12   | Alice        |
|    E2      | STAT12   | Alice        |
|    E3      | LAOB12   | Toto         |

`compute_elementary_deps` returns a single FD:

```
{n_etudiant} → nom_etudiant
```

Candidate key: `K = {n_etudiant, ue}`.

**2NF test:** for `{n_etudiant} → nom_etudiant`,
- C₁: `{n_etudiant}` is not a candidate key (the key is `{n_etudiant, ue}`),
- C₂: `nom_etudiant` is in no candidate key,
- C₃: every attribute of the LHS (`n_etudiant`) *does* belong to the candidate key K — so C₃ fails.

None of the conditions are satisfied. The table is in **1NF** only.

### Additional defensive tests

`tests.ml` also exercises edge cases:

- `check_table` on a table with a forbidden `VNull` in a non-nullable column → rejected ✓
- `check_table` on a table with a type mismatch (`VText` in a `TInt` column) → rejected ✓
- `insert` of an incompatible row → `Failure` raised ✓
- `insert` of a row with the wrong arity → `Failure` raised ✓
- `restrict commande (fun r → n_comm = "C01")` → 1 row returned ✓
- `projection commande ["n_produit"; "type"]` → 2-column table ✓
- `prod commande produit` → 15 rows (5 × 3) ✓

---

## Complexity analysis

Let `R = number of rows`, `C = number of columns`, `K = number of candidate keys`, `E = number of elementary FDs`. Worst-case time complexity, as derived in the report:

| function                  | complexity                                                          |
|---------------------------|---------------------------------------------------------------------|
| `verify_df`               | `O(R² · C²)`                                                        |
| `sous_listes`             | `O(2^C)`                                                            |
| `compute_deps`            | `O(C² · R² · 2^{2C})`                                               |
| `compute_elementary_deps` | `O(C² · R² · 2^{2C} + C³ · 2^{3C})`                                  |
| `est_cle_candidate`       | `O(C² · R² · 2^C)`                                                  |
| `respecte_2NF / 3NF`      | `O(C² · R² · 2^C)`                                                  |
| `normalization_level`     | `O(C³ · R² · 2^{2C} + C³ · 2^{3C})`                                 |

### Reading the complexities

In real databases, `R` is large (thousands of rows) while `C` is small (10 to 50 columns). The `O(2^{3C})` term is therefore the wall: doubling the number of columns multiplies the runtime by `2^{3 × C}`. For a 20-column table that's a factor of 2^30 ≈ 10⁹ over a 10-column table.

The program is therefore an excellent **didactic** tool — it makes the formal definitions of FDs and normal forms run end-to-end — but it is not adapted to schemas with more than ~15 columns. A production-grade normaliser would replace the exhaustive `P(Cols) × P(Cols)` enumeration with **closure algorithms** (Armstrong's axioms, attribute closure) that run in polynomial time.

---

## Important to know

1. **Implementing `sous_listes` purely with `fold_left`.** Generating `P(L)` is naturally recursive; reformulating it as structural induction with an accumulator (`Aₖ = Aₖ₋₁ ∪ {S ∪ {aₖ} | S ∈ Aₖ₋₁}`) took a few iterations and a sketch on paper inspired by the first logic course.

2. **`check_table` is *not* just length-checking.** A first naive version that only checked that every row had the right arity passed obviously-broken tables (a `VText` in a `TInt` column). The correct implementation walks schema and row in lock-step inside a `fold_left` and rejects every type mismatch and every nullability violation.

3. **Building a valid 1NF test case.** I assumed that a table with a "partial dependency" violating 2NF would automatically be detected as 1NF — and the algorithm kept returning 3NF instead. After re-reading my normaliser convinced I had a bug, I realised the bug was in my *data*: when every non-key attribute is unique in the test set, the algorithm correctly infers spurious extra candidate keys, and the "non-key" attribute becomes *part* of a candidate key, which satisfies C₂. The fix was to introduce real redundancy (duplicate values of `nom_etudiant`) in the data. **Important lesson: this engine has no user-declared constraints; it infers them from the actual rows. The choice of test data therefore matters as much as the choice of test logic.**

---


## Author

**Ibrahima Diaby** — ENSIIE, first-year Computer Science & Applied Mathematics student, INPF12 project (2025-2026).
