set dotenv-load := true

default:
    just --list --unsorted

clean:
    mkosi clean -ff


sysexts: clean
    mkosi build

cayo: clean
    mkosi --profile cayo build

cayoloaded: clean
    mkosi --profile cayoloaded build

snow: clean
    mkosi --profile snow  build

snowloaded: clean
    mkosi --profile snowloaded  build

snowfield: clean
    mkosi --profile snowfield  build

snowfieldloaded: clean
    mkosi --profile snowfieldloaded  build