#!/usr/bin/env python3
"""Run inside a fresh GDM or GNOME session, as its user with its session bus."""
import ast
import subprocess

def call(*args):
    return subprocess.check_output(["gdbus", "call", *args], text=True).strip()

address, = ast.literal_eval(call(
    "--session", "--dest", "org.a11y.Bus", "--object-path", "/org/a11y/bus",
    "--method", "org.a11y.Bus.GetAddress"))
assert address, "accessibility bus returned an empty address"
# This is an accessibility consumer on the separate AT-SPI bus, not merely
# a package/file probe or a successful connection to the desktop session bus.
children = call(
    "--address", address, "--dest", "org.a11y.atspi.Registry",
    "--object-path", "/org/a11y/atspi/accessible/root",
    "--method", "org.a11y.atspi.Accessible.GetChildren")
print("PASS: accessibility bus activated and registry answered GetChildren")
print(children)
