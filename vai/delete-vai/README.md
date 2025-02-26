# Delete VAI

[⬅️ GO BACK](../README.md)

## Prerequisites

- `kubectl` with access to a Rancher cluster

#### Run directly via curl


#### Auto Mode

```sh
curl -sL https://raw.githubusercontent.com/brudnak/rancher-test-scripts/refs/heads/main/vai/delete-vai/script.sh | zsh -s -- --auto-mode
```

#### Dry Run

```sh
curl -sL https://raw.githubusercontent.com/brudnak/rancher-test-scripts/refs/heads/main/vai/delete-vai/script.sh | zsh -s -- --dry-run
```