# VAI Search DB Files for Namespace with SQLite Vacuum

[⬅️ GO BACK](../README.md)

## Prerequisites

- `kubectl` with access to a Rancher cluster
- `sqlite3` installed
- `zsh` shell

### Search for 'dadfish' namespace with vacuum

```sh
./script.sh dadfish
```

### Search for 'dadfish' namespace with vacuum via curl

```sh
curl -sL https://raw.githubusercontent.com/brudnak/rancher-test-scripts/refs/heads/main/vai/namespace-vacuum/script.sh | zsh -s -- dadfish
```
