set dotenv-load := true

default:
    just --list --unsorted

clean:
    mkosi clean -ff


sysexts: clean
    mkosi build

cayo: clean
    mkosi --profile cayo build

snow: clean
    mkosi --profile snow  build

snowloaded: clean
    mkosi --profile snowloaded  build

snowfield: clean
    mkosi --profile snowfield  build

snowfieldloaded: clean
    mkosi --profile snowfieldloaded  build