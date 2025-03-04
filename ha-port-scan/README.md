# HA Port Scan

[⬅️ GO BACK](../README.md)

### Basic usage (assumes local.yaml is in current directory)

```sh
curl -s https://raw.githubusercontent.com/brudnak/rancher-test-scripts/refs/heads/main/ha-port-scan/script.sh | bash
```

### Specify a different kubeconfig file

```sh
curl -s https://raw.githubusercontent.com/brudnak/rancher-test-scripts/refs/heads/main/ha-port-scan/script.sh | KUBECONFIG_ENV=/path/to/your/kubeconfig.yaml bash
```

### Check a different port (example: port 8080, hex 1F90)

```sh
curl -s https://raw.githubusercontent.com/brudnak/rancher-test-scripts/refs/heads/main/ha-port-scan/script.sh | PORT_TO_CHECK=8080 PORT_HEX=1F90 bash
```

### Specify a different namespace

```sh
curl -s https://raw.githubusercontent.com/brudnak/rancher-test-scripts/refs/heads/main/ha-port-scan/script.sh | NAMESPACE=your-namespace bash
```