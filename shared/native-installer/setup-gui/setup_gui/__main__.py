# SPDX-License-Identifier: LGPL-2.1-or-later
# `python3 -m setup_gui` entry point (equivalent to the snosi-setup wrapper).
import sys

from .app import main

sys.exit(main())
