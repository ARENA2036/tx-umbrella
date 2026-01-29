import subprocess

def run_command(command, capture_output=False):
    result = subprocess.run(command, shell=True, check=True, text=True,
                            stdout=subprocess.PIPE if capture_output else None)
    return result.stdout.strip() if capture_output else None