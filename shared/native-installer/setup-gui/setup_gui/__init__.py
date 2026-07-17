# SPDX-License-Identifier: LGPL-2.1-or-later
#
# setup_gui -- the snosi-setup GTK4/libadwaita kiosk frontend package
# (T2, docs/plans/2026-07-17-graphical-installer-plan.md).
#
# Layering rule (load-bearing for tests): model.py and data.py must never
# import GTK/GI -- test/snosi-setup-model-test.py runs them on hosts with no
# GTK at all. Only app.py and pages.py may touch gi.

__version__ = "0.1.0"
