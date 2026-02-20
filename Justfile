set dotenv-load := true

just := "/home/linuxbrew/.linuxbrew/bin/just"
mkosi := `which mkosi`

default:
    {{just}} --list --unsorted

clean:
    sudo PATH="$PATH" {{just}} _clean

sysexts:
    sudo PATH="$PATH" {{just}} _sysexts

snow:
    sudo PATH="$PATH" {{just}} _snow
    sudo PATH="$PATH" {{just}} _containerfile-build snow "Snow Linux OS Image"

snowloaded:
    sudo PATH="$PATH" {{just}} _snowloaded
    sudo PATH="$PATH" {{just}} _containerfile-build snowloaded "Snow Loaded Linux OS Image"

snowfield:
    sudo PATH="$PATH" {{just}} _snowfield
    sudo PATH="$PATH" {{just}} _containerfile-build snowfield "Snowfield Linux OS Image"

snowfieldloaded:
    sudo PATH="$PATH" {{just}} _snowfieldloaded
    sudo PATH="$PATH" {{just}} _containerfile-build snowfieldloaded "Snow Field Loaded Linux OS Image"

cayo:
    sudo PATH="$PATH" {{just}} _cayo
    sudo PATH="$PATH" {{just}} _containerfile-build cayo "Cayo Linux Server Image"

cayoloaded:
    sudo PATH="$PATH" {{just}} _cayoloaded
    sudo PATH="$PATH" {{just}} _containerfile-build cayoloaded "Cayo Loaded Linux Server Image"

test-install image="snow":
    sudo PATH="$PATH" {{just}} _test-install {{image}}

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
_containerfile-build profile description:
    podman build \
      --label containers.bootc=1 \
      --annotation containers.bootc=1 \
      --annotation org.opencontainers.image.vendor=frostyard \
      --annotation "org.opencontainers.image.title={{profile}}" \
      --annotation "org.opencontainers.image.description={{description}}" \
      -f Containerfile \
      -t {{profile}} \
      output/{{profile}}/

[private]
_test-install image="snow":
    ./test/bootc-install-test.sh {{image}}
