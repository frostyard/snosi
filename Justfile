set dotenv-load := true

default:
    just --list --unsorted

clean:
    mkosi clean


sysexts: clean
    mkosi build

cayo: clean
    mkosi --profile 10-image-cayo --profile 20-kernel-stock --profile 80-finalize-bootc --profile 90-output-oci build

snow: clean
    mkosi --profile 10-image-snow --profile 20-kernel-backports --profile 80-finalize-bootc --profile 90-output-oci build

snowloaded: clean
    mkosi --profile 10-image-snow --profile 20-kernel-backports --profile 30-packages-loaded --profile 40-name-snowloaded --profile 80-finalize-bootc --profile 90-output-oci build

snowfield: clean
    mkosi --profile 10-image-snow --profile 20-kernel-surface --profile 40-name-snowfield --profile 80-finalize-bootc --profile 90-output-oci build

snowfieldloaded: clean
    mkosi --profile 10-image-snow --profile 20-kernel-surface --profile 30-packages-loaded --profile 40-name-snowfieldloaded --profile 80-finalize-bootc --profile 90-output-oci build