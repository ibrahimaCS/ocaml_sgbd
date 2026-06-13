# =============================================================================
# Makefile for the OCaml RDBMS project (INPF12 ENSIIE 2025-2026)
# =============================================================================
# Available targets:
#   make            -> build the tests binary
#   make run        -> build and run the tests
#   make toplevel   -> open an OCaml toplevel with projet.ml loaded
#   make clean      -> remove every build artifact
# =============================================================================

# --- Compiler ---
OCAMLC   = ocamlc
OCAMLOPT = ocamlopt

# --- Source files ---

SRC_PROJET = projet.ml
SRC_TESTS  = tests.ml
GEN_SRC    = _build/all.ml

# --- Outputs ---
EXEC = tests_exec

# --- Default target ---
all: $(EXEC)

# Generated single-file source: the body of projet.ml followed by tests.ml
$(GEN_SRC): $(SRC_PROJET) $(SRC_TESTS) | _build
	cat $(SRC_PROJET) > $@
	echo "" >> $@
	grep -v '^#use' $(SRC_TESTS) >> $@


# Build the bytecode executable from the generated single-file source
$(EXEC): $(GEN_SRC)
	$(OCAMLC) -o $@ $(GEN_SRC)


# Create the build directory if missing
_build:
	mkdir -p _build

# Build then run the tests
run: $(EXEC)
	./$(EXEC)

# Open an interactive toplevel with the project loaded; very handy when you
# just want to type a few expressions to inspect a table or test a function.
toplevel:
	ocaml -init $(SRC_PROJET)

# Clean every build artifact
clean:
	rm -rf _build $(EXEC) *.cmi *.cmo *.cmx *.o

.PHONY: all run toplevel clean

