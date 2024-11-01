# VAI Search DB Files for Namespace

[⬅️ GO BACK](../README.md)

## Prerequisites

- `kubectl` with access to a Rancher cluster
- `sqlite3` installed
- `zsh` shell

### Search for 'dadfish' namespace for up to 5 minutes

```sh
./check-namespace.sh dadfish 5
```

#### Search for 'myspace' namespace for up to 2 minutes

```sh
./check-namespace.sh myspace 2
```

#### Run directly via curl, search for 'myspace' for 3 minutes

```sh
curl -sL https://raw.githubusercontent.com/brudnak/rancher-test-scripts/refs/heads/main/vai/namespace/script.sh | zsh -s -- myspace 3
```
