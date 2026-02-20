set dotenv-load := true

just := "/home/linuxbrew/.linuxbrew/bin/just"
mkosi := "/home/bjk/.local/bin/mkosi"

default:
    {{just}} --list --unsorted

clean:
    sudo {{just}} _clean

sysexts:
    sudo {{just}} _sysexts

snow:
    sudo {{just}} _snow

snowloaded:
    sudo {{just}} _snowloaded

snowfield:
    sudo {{just}} _snowfield

snowfieldloaded:
    sudo {{just}} _snowfieldloaded

cayo:
    sudo {{just}} _cayo

cayoloaded:
    sudo {{just}} _cayoloaded

test-install image="output/snow":
    sudo {{just}} _test-install {{image}}

# Private targets (run as root via sudo)

[private]
_clean:
    {{mkosi}} clean -ff

[private]
_sysexts: _clean
    {{mkosi}} build

[private]
_snow: _clean
    {{mkosi}} --profile snow build

[private]
_snowloaded: _clean
    {{mkosi}} --profile snowloaded build

[private]
_snowfield: _clean
    {{mkosi}} --profile snowfield build

[private]
_snowfieldloaded: _clean
    {{mkosi}} --profile snowfieldloaded build

[private]
_cayo: _clean
    {{mkosi}} --profile cayo build

[private]
_cayoloaded: _clean
    {{mkosi}} --profile cayoloaded build

[private]
_test-install image="output/snow":
    ./test/bootc-install-test.sh {{image}}
