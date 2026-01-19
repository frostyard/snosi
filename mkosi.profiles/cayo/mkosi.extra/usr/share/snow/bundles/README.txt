# Brew Bundles

Files in this directory are in `brew bundle` format, and can be installed with the command:

```bash
brew bundle --file=/usr/share/snow/xxx.Brewfile
```

## Convention

By convention the first line in each Brewfile is a comment with a description of the bundle:

```bash
# Recommended CLI Tools
tap "valkyrie00/bbrew"
brew "atuin"
brew "bat"
...

```

This convention supports automated tooling reading the first line, removing the `#`
and displaying the comment as a title.