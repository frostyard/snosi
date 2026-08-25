#!/bin/bash

# snosi override: user-unit enablement is preset-driven on Flurry
# (shared/flurry/tree/usr/lib/systemd/user-preset/90-flurry.preset), applied
# at image build by `systemctl --global preset-all` and on first boot by
# preset-global.service. Nothing to do at first run.

exit 0
