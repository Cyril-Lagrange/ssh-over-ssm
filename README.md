# SSH over SSM

## 1. Setup Local Environment on Linux, Mac, or Windows

### 1.1 Install AWS CLI

**Linux:**
```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
```

**macOS:**
```bash
curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
sudo installer -pkg AWSCLIV2.pkg -target /
```

**Windows:**
```powershell
# Download and run the MSI installer
Invoke-WebRequest -Uri "https://awscli.amazonaws.com/AWSCLIV2.msi" -OutFile "AWSCLIV2.msi"
Start-Process msiexec.exe -ArgumentList "/i AWSCLIV2.msi /quiet" -Wait
```

Verify installation:
```bash
aws --version
```

### 1.2 Install AWS CLI SSM Plugin

**Linux:**
```bash
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o "session-manager-plugin.deb"
sudo dpkg -i session-manager-plugin.deb
```

**macOS:**
```bash
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/mac/sessionmanager-bundle.zip" -o "sessionmanager-bundle.zip"
unzip sessionmanager-bundle.zip
sudo ./sessionmanager-bundle/install -i /usr/local/sessionmanagerplugin -b /usr/local/bin/session-manager-plugin
```

**Windows:**
```powershell
# Download and install the MSI package
Invoke-WebRequest -Uri "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/windows/SessionManagerPluginSetup.exe" -OutFile "SessionManagerPluginSetup.exe"
Start-Process -FilePath "SessionManagerPluginSetup.exe" -ArgumentList "/S" -Wait
```

Verify installation:
```bash
session-manager-plugin
```


## 2. Create an EC2 instance and connect to it using SSM.

### 2.1 Create EC2 instance

### 2.1 Create EC2 Instance

1. **Launch EC2 Instance:**
   - Go to AWS Console > EC2 > Launch Instance
   - Search for "Rocky Linux" in AWS Marketplace
   - Select Rocky Linux 8 or 9 AMI

2. **Configure Instance:**
   - Choose instance type (t3.medium recommended)
   - Create or select a key pair for SSH access. Save the key file in your .ssh folder.
   - **Important:** Attach an IAM instance profile with SSM permissions (AmazonSSMManagedInstanceCore policy)

3. **Security Group:**
   - No inbound rules needed (SSM uses outbound HTTPS)
   - Ensure outbound HTTPS (443) is allowed

4. **Launch Instance:**
   - Review settings and launch
   - Wait for instance to reach "Running" state and pass status checks

### 2.2 Configure SSH for SSM Proxy

Add the following configuration to your SSH config file (`~/.ssh/config` on Linux/Mac or `C:\Users\<username>\.ssh\config` on Windows):

**Linux/Mac:**
```
Host <friendly-host-name>
    IdentityFile ~/.ssh/<keyfile>.pem
    User rocky
    HostName <instance-id>
    ProxyCommand sh -c "~/.ssh/ssm-proxy.sh %h %p <aws-region> <aws-profile>"
```

**Windows:**
```
Host <friendly-host-name>
    IdentityFile 'c:\Users\<username>\.ssh\<key-file>.pem'
    User rocky
    HostName <instance-id>
    ProxyCommand "C:\Windows\System32\cmd.exe" /C "c:\Users\<username>\.ssh\ssm-proxy.bat" %h %p <aws_region> <aws_profile>
```

Replace placeholders with your actual values:
- `<friendly-host-name>`: Your chosen alias for the host
- `<keyfile>` or `<key-file>`: Your EC2 key pair file
- `<instance-id>`: The EC2 instance ID
- `<aws-region>`: AWS region (e.g., us-east-1)
- `<aws-profile>`: Your AWS profile name
- `<username>`: Your Windows username

Make sure to copy the relevant ssm-proxy script to you .ssh folder.


## Connect to instance

After completing the setup, to connect to an instance:
- Authenticate with AWS, if you are using IAM Identity Center use `aws sso login` to authenticate
- ssh into your instance using the friendly-host-name: ssh friendly-host-name
- you can also use scp to copy files to your instance scp myfile friendly-host-name:~/
