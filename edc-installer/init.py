import sys
from services.utils import *

def main():
    if len(sys.argv) != 6:
        print("Usage: python init.py <context> <name> <type> <values_file> <namespace>")
        sys.exit(1)

    context, name, deploy_type, values_files, namespace = sys.argv[1:]

    ensure_kubectl_installed()
    switch_kubectl_context()
    update_helm_dependencies()
    install_helm_chart(name, values_files, namespace)
    print("Deployment complete.")

if __name__ == "__main__":
    #main()
    values_files = ["values-arena2036-x-edcs.yaml", "values-secrets.yaml"]
    ensure_kubectl_installed()
    ensure_helm_installed()
    update_helm_dependencies()
    upgrade_helm_chart("umbrella-edc", values_files, "release24-12")
    #install_helm_chart("umbrella-edc", values_files, "release24-12")
    #raise ValueError("Invalid deployment type. Use 'install' or 'upgrade'.")
    print("Hello World")