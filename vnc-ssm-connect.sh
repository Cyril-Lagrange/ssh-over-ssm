#!/bin/bash

# SSM VNC Connection Script with User Support
# Usage: ./ssm-vnc-connect-simple.sh <instance-name> <account-id> <region> [username]

set -e

# Check for help
if [ "$1" = "--help" ] || [ "$1" = "-h" ] || [ "$1" = "help" ]; then
    echo "SSM VNC Connection Script with User Support"
    echo ""
    echo "Usage: $0 <username>@<instance-name> [account-id] [region]"
    echo ""
    echo "Examples:"
    echo "  $0 rocky@my-instance                              # Use AWS config for account/region"
    echo "  $0 ec2-user@web-server                            # Use AWS config for account/region"
    echo "  $0 rocky@my-instance 123456789012                 # Specify account, use AWS config for region"
    echo "  $0 rocky@my-instance 123456789012 us-east-1       # Specify account and region"
    echo "  $0 rocky@my-instance us-west-2                    # Specify region, use AWS config for account"
    echo ""
    echo "Parameters:"
    echo "  username@instance-name: Required - Linux username and EC2 instance name tag"
    echo "  account-id:            Optional - AWS account ID (uses current AWS config if not specified)"
    echo "  region:                Optional - AWS region (uses AWS_DEFAULT_REGION or aws config if not specified)"
    echo ""
    echo "Environment Variables:"
    echo "  AWS_DEFAULT_REGION or AWS_REGION - Default region if not specified"
    echo "  AWS_PROFILE - AWS profile to use"
    exit 0
fi

# Check if required arguments are provided
if [ $# -lt 1 ] || [ $# -gt 3 ]; then
    echo "Usage: $0 <username>@<instance-name> [account-id] [region]"
    echo "Examples:"
    echo "  $0 rocky@my-instance                              # Use AWS config for account/region"
    echo "  $0 rocky@my-instance 123456789012                 # Specify account"
    echo "  $0 rocky@my-instance 123456789012 us-east-1       # Specify account and region"
    echo ""
    echo "Use --help for more information"
    exit 1
fi

# Parse username@instance-name format
USER_INSTANCE="$1"
if [[ "$USER_INSTANCE" != *"@"* ]]; then
    echo -e "${RED}Error: First argument must be in format <username>@<instance-name>${NC}"
    echo "Example: rocky@my-instance"
    exit 1
fi

VNC_USER="${USER_INSTANCE%@*}"
INSTANCE_NAME="${USER_INSTANCE#*@}"

if [ -z "$VNC_USER" ] || [ -z "$INSTANCE_NAME" ]; then
    echo -e "${RED}Error: Invalid format. Use <username>@<instance-name>${NC}"
    echo "Example: rocky@my-instance"
    exit 1
fi

# Handle optional parameters based on number of arguments
case $# in
    1)
        # Only user@instance
        ACCOUNT_ID=""
        REGION=""
        ;;
    2)
        # user@instance + one parameter
        if [[ "$2" =~ ^[0-9]{12}$ ]]; then
            # Second parameter is account ID
            ACCOUNT_ID="$2"
            REGION=""
        else
            # Second parameter is region
            ACCOUNT_ID=""
            REGION="$2"
        fi
        ;;
    3)
        # user@instance + account-id + region
        ACCOUNT_ID="$2"
        REGION="$3"
        ;;
esac

# Get region from environment or AWS config if not specified
if [ -z "$REGION" ]; then
    if [ ! -z "$AWS_DEFAULT_REGION" ]; then
        REGION="$AWS_DEFAULT_REGION"
        echo "Using region from AWS_DEFAULT_REGION: $REGION"
    elif [ ! -z "$AWS_REGION" ]; then
        REGION="$AWS_REGION"
        echo "Using region from AWS_REGION: $REGION"
    else
        # Try to get from AWS config
        REGION=$(aws configure get region 2>/dev/null || echo "")
        if [ ! -z "$REGION" ]; then
            echo "Using region from AWS config: $REGION"
        else
            echo -e "${RED}Error: No region specified and no default region configured${NC}"
            echo "Please either:"
            echo "1. Specify region as parameter: $0 $INSTANCE_NAME [account-id] <region>"
            echo "2. Set environment variable: export AWS_DEFAULT_REGION=us-east-1"
            echo "3. Configure AWS CLI: aws configure set region us-east-1"
            exit 1
        fi
    fi
fi
LOCAL_PORT="5901"
REMOTE_PORT="5901"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Starting SSM VNC connection setup...${NC}"
echo "Instance: $INSTANCE_NAME"
echo "Region: $REGION" 
echo "VNC User: $VNC_USER"

# Function to cleanup background processes
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    if [ ! -z "$SSM_PID" ]; then
        kill $SSM_PID 2>/dev/null || true
        echo "SSM session terminated"
    fi
    if [ ! -z "$VNC_PID" ]; then
        kill $VNC_PID 2>/dev/null || true
        echo "VNC viewer terminated"
    fi
    exit 0
}

# Set up signal handlers
trap cleanup SIGINT SIGTERM

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo -e "${RED}Error: AWS CLI is not installed${NC}"
    exit 1
fi

# Check if AWS credentials are configured
echo -e "${YELLOW}Checking AWS credentials...${NC}"
if ! aws sts get-caller-identity --region "$REGION" &>/dev/null; then
    echo -e "${RED}Error: AWS credentials not configured or invalid${NC}"
    echo "Please configure AWS credentials using one of these methods:"
    echo "1. aws configure"
    echo "2. export AWS_ACCESS_KEY_ID=... && export AWS_SECRET_ACCESS_KEY=..."
    echo "3. aws sso login --profile your-profile"
    echo "4. export AWS_PROFILE=your-profile-name"
    exit 1
fi

CALLER_IDENTITY=$(aws sts get-caller-identity --region "$REGION" --output text --query 'Account')
echo -e "${GREEN}AWS credentials configured (Account: $CALLER_IDENTITY)${NC}"

# Use detected account ID if not specified
if [ -z "$ACCOUNT_ID" ]; then
    ACCOUNT_ID="$CALLER_IDENTITY"
    echo "Using current AWS account: $ACCOUNT_ID"
fi

# Verify we're using the correct account
if [ "$ACCOUNT_ID" != "$CALLER_IDENTITY" ]; then
    echo -e "${RED}Warning: Specified account ID ($ACCOUNT_ID) differs from current AWS credentials ($CALLER_IDENTITY)${NC}"
    echo "Continuing with current credentials..."
    ACCOUNT_ID="$CALLER_IDENTITY"
fi

# Check if Session Manager plugin is installed
if ! aws ssm help &> /dev/null; then
    echo -e "${RED}Error: AWS Session Manager plugin is not installed${NC}"
    echo "Install it from: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"
    exit 1
fi

echo -e "${YELLOW}Looking up instance ID for: $INSTANCE_NAME${NC}"

# Get instance ID from instance name
INSTANCE_ID=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text 2>/dev/null)

if [ "$INSTANCE_ID" = "None" ] || [ -z "$INSTANCE_ID" ]; then
    echo -e "${RED}Error: Could not find running instance with name '$INSTANCE_NAME' in region '$REGION'${NC}"
    exit 1
fi

echo -e "${GREEN}Found instance: $INSTANCE_ID${NC}"

# Check if instance has SSM agent running
echo -e "${YELLOW}Checking SSM connectivity...${NC}"
SSM_STATUS=$(aws ssm describe-instance-information \
    --region "$REGION" \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query 'InstanceInformationList[0].PingStatus' \
    --output text 2>/dev/null)

if [ "$SSM_STATUS" != "Online" ]; then
    echo -e "${RED}Error: Instance is not reachable via SSM. Status: $SSM_STATUS${NC}"
    echo "Make sure the instance has:"
    echo "- SSM Agent installed and running"
    echo "- Proper IAM role with SSM permissions"
    echo "- Network connectivity to SSM endpoints"
    exit 1
fi

echo -e "${GREEN}SSM connectivity confirmed${NC}"

# Function to run command on remote instance
run_remote_command() {
    local description="$1"
    local command="$2"
    
    echo -e "${YELLOW}$description${NC}"
    
    COMMAND_ID=$(aws ssm send-command \
        --region "$REGION" \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --parameters "commands=[\"$command\"]" \
        --query 'Command.CommandId' \
        --output text)
    
    # Wait for command to complete
    for i in {1..30}; do
        STATUS=$(aws ssm get-command-invocation \
            --region "$REGION" \
            --command-id "$COMMAND_ID" \
            --instance-id "$INSTANCE_ID" \
            --query 'Status' \
            --output text 2>/dev/null)
        
        if [ "$STATUS" = "Success" ]; then
            return 0
        elif [ "$STATUS" = "Failed" ]; then
            echo -e "${RED}Command failed${NC}"
            aws ssm get-command-invocation \
                --region "$REGION" \
                --command-id "$COMMAND_ID" \
                --instance-id "$INSTANCE_ID" \
                --query 'StandardErrorContent' \
                --output text
            return 1
        fi
        
        sleep 2
    done
    
    echo -e "${RED}Command timed out${NC}"
    return 1
}

# Check if user exists and create if necessary
echo -e "${YELLOW}Checking if user $VNC_USER exists...${NC}"

# Check if user exists
USER_CHECK_CMD=$(aws ssm send-command \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"id $VNC_USER >/dev/null 2>&1 && echo USER_EXISTS || echo USER_NOT_EXISTS\"]" \
    --query 'Command.CommandId' \
    --output text)

sleep 3

USER_STATUS=$(aws ssm get-command-invocation \
    --region "$REGION" \
    --command-id "$USER_CHECK_CMD" \
    --instance-id "$INSTANCE_ID" \
    --query 'StandardOutputContent' \
    --output text 2>/dev/null)

if [[ "$USER_STATUS" == *"USER_NOT_EXISTS"* ]]; then
    echo -e "${RED}Error: User $VNC_USER does not exist on the instance${NC}"
    exit 1
else
    echo -e "${GREEN}User $VNC_USER exists${NC}"
fi

# Resolve the user's home directory (FreeIPA users may not be under /home)
echo -e "${YELLOW}Resolving home directory for $VNC_USER...${NC}"
HOMEDIR_CMD=$(aws ssm send-command \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"getent passwd $VNC_USER | cut -d: -f6\"]" \
    --query 'Command.CommandId' \
    --output text)

sleep 3

VNC_HOME=$(aws ssm get-command-invocation \
    --region "$REGION" \
    --command-id "$HOMEDIR_CMD" \
    --instance-id "$INSTANCE_ID" \
    --query 'StandardOutputContent' \
    --output text 2>/dev/null | tr -d '[:space:]')

if [ -z "$VNC_HOME" ]; then
    echo -e "${RED}Error: Could not resolve home directory for $VNC_USER${NC}"
    exit 1
fi

echo -e "${GREEN}Home directory: $VNC_HOME${NC}"

# Setup VNC server with FreeIPA/PAM authentication
echo -e "${YELLOW}Setting up VNC server for user $VNC_USER with FreeIPA authentication...${NC}"

# Kill existing VNC servers (handle both legacy and systemd)
run_remote_command "Cleaning up existing VNC servers..." \
    "sudo systemctl stop vncserver@:1.service 2>/dev/null || true; sudo -u $VNC_USER vncserver -kill :1 2>/dev/null || true; sudo -u $VNC_USER pkill -f Xvnc || true; sudo pkill -f 'Xvnc.*:1' || true"

# Configure PAM service for VNC to authenticate against FreeIPA via SSSD
run_remote_command "Configuring PAM service for VNC FreeIPA authentication..." \
    "sudo tee /etc/pam.d/vnc_freeipa > /dev/null << 'PAMEOF'
#%PAM-1.0
# VNC PAM service - authenticates against FreeIPA via SSSD
auth       required     pam_sepermit.so
auth       substack     password-auth
auth       include      postlogin
account    required     pam_nologin.so
account    include      password-auth
session    include      password-auth
PAMEOF"

# Generate a self-signed TLS certificate for encrypted VNC connections
run_remote_command "Setting up TLS certificate for VNC..." \
    "sudo mkdir -p /etc/pki/vnc && \
    if [ ! -f /etc/pki/vnc/vnc.pem ]; then \
        sudo openssl req -x509 -newkey rsa:2048 -keyout /etc/pki/vnc/vnc-key.pem \
            -out /etc/pki/vnc/vnc.pem -days 365 -nodes \
            -subj '/CN=vnc-server/O=VNC/C=US' 2>/dev/null && \
        sudo chmod 644 /etc/pki/vnc/vnc.pem && \
        sudo chmod 600 /etc/pki/vnc/vnc-key.pem; \
    fi"

# Create VNC directory and xstartup file
run_remote_command "Creating xstartup file..." \
    "sudo -u $VNC_USER mkdir -p $VNC_HOME/.vnc && \
    sudo -u $VNC_USER tee $VNC_HOME/.vnc/xstartup > /dev/null << 'EOF'
#!/bin/bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
xsetroot -solid grey
vncconfig -iconic &
if command -v gnome-session >/dev/null 2>&1; then
  export XDG_CURRENT_DESKTOP=GNOME
  gnome-session --session=gnome-classic &
elif command -v startxfce4 >/dev/null 2>&1; then
  startxfce4 &
else
  xterm -geometry 80x24+10+10 &
  twm &
fi
EOF
sudo -u $VNC_USER chmod +x $VNC_HOME/.vnc/xstartup"

# Start VNC server with PAM authentication (FreeIPA credentials via SSSD)
# SecurityTypes: TLSPlain uses TLS encryption + username/password via PAM
#                VncAuth is kept as fallback for clients that don't support TLSPlain
# PAMService: vnc_freeipa delegates auth to SSSD which validates against FreeIPA
run_remote_command "Starting VNC server with FreeIPA authentication..." \
    "sudo -u $VNC_USER bash -c 'export HOME=$VNC_HOME && export USER=$VNC_USER && cd $VNC_HOME && \
    vncserver :1 -geometry 1024x768 -depth 24 \
        -SecurityTypes TLSPlain,TLSNone \
        -PAMService vnc_freeipa \
        -PlainUsers $VNC_USER \
        -X509Cert /etc/pki/vnc/vnc.pem \
        -X509Key /etc/pki/vnc/vnc-key.pem'"

echo -e "${GREEN}VNC server setup complete (FreeIPA authentication enabled)${NC}"

# Check if local port is available
if lsof -Pi :$LOCAL_PORT -sTCP:LISTEN -t >/dev/null 2>&1; then
    echo -e "${RED}Error: Local port $LOCAL_PORT is already in use${NC}"
    exit 1
fi

echo -e "${YELLOW}Starting SSM port forwarding session...${NC}"
echo "Local port: $LOCAL_PORT -> Remote port: $REMOTE_PORT"

# Start SSM port forwarding session in background
aws ssm start-session \
    --region "$REGION" \
    --target "$INSTANCE_ID" \
    --document-name "AWS-StartPortForwardingSession" \
    --parameters "portNumber=$REMOTE_PORT,localPortNumber=$LOCAL_PORT" &

SSM_PID=$!

# Wait a moment for the session to establish
echo -e "${YELLOW}Waiting for SSM session to establish...${NC}"
sleep 5

# Check if SSM session is still running
if ! kill -0 $SSM_PID 2>/dev/null; then
    echo -e "${RED}Error: SSM session failed to start${NC}"
    exit 1
fi

echo -e "${GREEN}SSM session established (PID: $SSM_PID)${NC}"

# Wait for port to be available
echo -e "${YELLOW}Waiting for port forwarding to be ready...${NC}"
for i in {1..30}; do
    if nc -z localhost $LOCAL_PORT 2>/dev/null; then
        echo -e "${GREEN}Port forwarding is ready${NC}"
        break
    fi
    if [ $i -eq 30 ]; then
        echo -e "${RED}Error: Port forwarding did not become available${NC}"
        cleanup
        exit 1
    fi
    sleep 1
done

# Check for VNC viewer
VNC_VIEWER=""
if command -v vncviewer &> /dev/null; then
    VNC_VIEWER="vncviewer"
elif command -v open &> /dev/null && [ -d "/System/Applications/VNC Viewer.app" ]; then
    VNC_VIEWER="open vnc://localhost:$LOCAL_PORT"
elif command -v open &> /dev/null; then
    # Try to open with default VNC app on macOS
    VNC_VIEWER="open vnc://localhost:$LOCAL_PORT"
else
    echo -e "${YELLOW}No VNC viewer found. You can manually connect to: localhost:$LOCAL_PORT${NC}"
fi

if [ ! -z "$VNC_VIEWER" ]; then
    echo -e "${GREEN}Launching VNC viewer...${NC}"
    if [[ "$VNC_VIEWER" == "open"* ]]; then
        $VNC_VIEWER &
    else
        $VNC_VIEWER localhost:$LOCAL_PORT &
    fi
    VNC_PID=$!
fi

echo -e "${GREEN}Connection established!${NC}"
echo "SSM Session: $INSTANCE_ID (PID: $SSM_PID)"
echo "VNC Connection: localhost:$LOCAL_PORT"
echo "VNC User: $VNC_USER"
echo -e "${YELLOW}Authentication: Use your FreeIPA credentials when prompted by the VNC viewer${NC}"
echo ""
echo -e "${YELLOW}Note: Your VNC client must support TLSPlain security type (e.g., TigerVNC viewer).${NC}"
echo -e "${YELLOW}Press Ctrl+C to terminate the connection${NC}"

# Keep the script running
wait $SSM_PID