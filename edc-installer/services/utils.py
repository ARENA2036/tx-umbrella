import subprocess
import os
from utils.shellUtils import run_command
from configuration import SUB_DIR

def ensure_kubectl_installed():
    try:
        run_command("kubectl version --client", capture_output=True)
        print("kubectl is already installed.")
    except subprocess.CalledProcessError:
        print("Installing kubectl...")
        run_command("curl -LO -s https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl")
        run_command("chmod +x kubectl")
        run_command("sudo mv kubectl /usr/local/bin/")
        run_command("kubectl version --client")
        print("kubectl installed successfully.")

def switch_kubectl_context(context_name):
    run_command(f"kubectl config use-context {context_name}")

def ensure_helm_installed():
    try:
        run_command("helm version --client", capture_output=True)
        print("helm is already installed.")
    except subprocess.CalledProcessError:
        print("Installing kubectl...")
        #run_command("curl -LO -s https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl")
        #run_command("chmod +x kubectl")
        #run_command("sudo mv kubectl /usr/local/bin/")
        #run_command("helm version --client")
        print("kubectl installed successfully.")

def update_helm_dependencies():
    os.chdir(f"../{SUB_DIR}")
    print(f"Working directory: {os.getcwd()}")
    run_command("helm dependency update ../tx-data-provider")
    run_command("helm dependency update")

def install_helm_chart(deployment_name:str, values_files:list, namespace:str):

    formatted_files = " ".join([" -f " + file for file in values_files])
    print(f"Installing helm chart with values from {values_files}...")
    run_command(f"helm install {deployment_name}  {formatted_files} --namespace {namespace} --debug .")
    print(f"Install helm chart successful...")


def upgrade_helm_chart(deployment_name:str, values_files:list, namespace:str):

    formatted_files = " ".join([" -f " + file for file in values_files])
    print(f"Upgrading helm chart with values from {values_files}...")
    run_command(f"helm upgrade -i {deployment_name} {formatted_files} --namespace {namespace} --debug .")
    print(f"Upgrade helm chart successful...")