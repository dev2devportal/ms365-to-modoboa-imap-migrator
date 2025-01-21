# MS365 to Modoboa Migration Tool

A secure, robust tool for migrating email accounts from Microsoft 365 Exchange Online to Modoboa IMAP servers. Supports multi-account migration with state tracking and resume capabilities.

## Features

- Full mailbox migration from MS365 to Modoboa
- Multi-account support with state tracking
- Secure credential and configuration handling
- Progress tracking and resume capability
- Duplicate message prevention
- MIME format preservation
- Folder structure preservation
- Detailed logging and validation

## Security Features

- Modern Authentication for MS365 access
- Azure B2C server routing
- SSL/TLS enforcement
- Secure credential handling
- File permission enforcement
- No hardcoded credentials
- Clean error handling

## Prerequisites

### Required Packages

```bash
# Debian/Ubuntu
sudo apt-get update
sudo apt-get install -y \
    openssl \
    jq \
    yq \
    flock \
    parallel \
    azure-cli

# Install Azure CLI (if not installed)
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
az extension add --name account
```

### Azure Setup Requirements

1. Azure AD Application Registration:
   - Access to Azure AD Admin portal
   - Ability to create Application Registration
   - Permission to grant admin consent for API permissions
   - Ability to create client secret

2. Required API Permissions:
   ```
   Microsoft Graph:
   - Mail.Read.All
   - Mail.ReadWrite.All
   - User.Read.All
   ```

### Modoboa Requirements

1. IMAP Server:
   - SSL/TLS enabled
   - Port 993 accessible
   - User accounts created
   - IMAP authentication working

2. Account Preparation:
   - Accounts must exist on Modoboa server
   - Sufficient storage available
   - IMAP access enabled
   - Working credentials

## Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/yourusername/ms365-modoboa-migration.git
   cd ms365-modoboa-migration
   ```

2. Create configuration directory:
   ```bash
   mkdir -p config
   chmod 700 config
   ```

3. Copy and customize configuration templates:
   ```bash
   cp examples/system_config.yaml config/
   cp examples/accounts.yaml config/
   chmod 600 config/*.yaml
   ```

4. Update configurations with your settings:
   ```bash
   # Use your preferred editor
   vi config/system_config.yaml
   vi config/accounts.yaml
   ```

5. Create required directories:
   ```bash
   mkdir -p logs stats messages
   chmod 755 logs stats messages
   ```
## Configuration

### Azure AD Application Setup

1. Register Application in Azure AD:
   - Sign in to Azure Portal
   - Navigate to Azure Active Directory
   - Select "App registrations"
   - Click "New registration"
   - Set name (e.g., "MS365 to Modoboa Migration Tool")
   - Select "Accounts in this organizational directory only"
   - Click "Register"

2. Record Application Details:
   - Application (client) ID
   - Directory (tenant) ID
   - Object ID

3. Create Client Secret:
   - In your application, go to "Certificates & secrets"
   - Click "New client secret"
   - Set description and expiration
   - Copy the secret value immediately (it won't be shown again)

4. Configure API Permissions:
   - Go to "API permissions"
   - Click "Add a permission"
   - Select "Microsoft Graph"
   - Choose "Application permissions"
   - Add required permissions:
     - Mail.Read.All
     - Mail.ReadWrite.All
     - User.Read.All
   - Click "Grant admin consent"

### System Configuration

Configure `config/system_config.yaml`:

```yaml
version: "1.0"

azure:
  subscription_id: "your-subscription-id"
  tenant_id: "your-tenant-id"
  client_id: "your-application-id"
  client_secret: "your-client-secret"
  admin_email: "admin@yourdomain.com"

source_system:
  type: "ms365"
  server: "outlook.office365.com"
  port: 993
  auth_type: "modern"
  timeout: 30
  retry_count: 3
  delay: 2

destination_system:
  type: "modoboa"
  server: "mail.yourdomain.com"
  port: 993
  auth_type: "basic"
  ssl: true
  timeout: 30
  retry_count: 3
  delay: 2

paths:
  base_dir: "/path/to/migration"
  download_dir: "messages"
  stats_dir: "stats"
  temp_dir: "/tmp/migration"
  log_dir: "logs"

processing:
  max_retries: 3
  request_delay: 0.5
  retry_delay: 2
  verify_delay: 1
  max_parallel_downloads: 3
  max_parallel_uploads: 1
  chunk_size: 10485760

logging:
  level: "info"
  format: "standard"
  retention: 30
  max_size: 104857600
```

### Account Configuration

Configure `config/accounts.yaml`:

```yaml
version: "1.0"

accounts:
  - email: "user1@yourdomain.com"
    source_password: "ms365-password"
    dest_password: "modoboa-password"
    enabled: true
    retry_count: 0
    folders:
      - source: "Inbox"
        dest: "INBOX"
      - source: "Sent Items"
        dest: "Sent"
  
  - email: "user2@yourdomain.com"
    source_password: "ms365-password"
    dest_password: "modoboa-password"
    enabled: true
    retry_count: 0

  # Add more accounts as needed
```

Important Security Notes:
1. Configuration files must have 600 permissions
2. Configuration directory should have 700 permissions
3. Never commit configuration files to version control
4. Keep client secrets and passwords secure
5. Regularly rotate client secrets and update configuration
## Usage

The migration tool provides a simple command-line interface through the `migrate.sh` script.

### Basic Commands

```bash
# Verify configuration and dependencies
./migrate.sh verify

# Show current migration status
./migrate.sh status

# Start download phase
./migrate.sh download

# Resume interrupted download
./migrate.sh --resume download

# Start upload phase
./migrate.sh upload

# Force retry of failed uploads
./migrate.sh --force upload
```

### Command Options

```bash
Usage: ./migrate.sh [options] <command>

Commands:
    download            Download emails from MS365
    upload             Upload emails to Modoboa
    status             Show migration status
    verify             Verify configuration
    help               Show this help message

Options:
    --config <dir>     Configuration directory (default: ./config)
    --resume           Resume from last position
    --force           Force reprocessing of completed items
    --reset           Clear all state and start fresh
```

### Migration Process

1. Initial Setup:
   ```bash
   # Verify configuration and dependencies
   ./migrate.sh verify
   ```

2. Download Phase:
   ```bash
   # Start downloading emails from MS365
   ./migrate.sh download
   
   # Check progress
   ./migrate.sh status
   
   # If interrupted, resume download
   ./migrate.sh --resume download
   ```

3. Upload Phase:
   ```bash
   # Start uploading to Modoboa
   ./migrate.sh upload
   
   # Check progress
   ./migrate.sh status
   
   # If needed, force retry of failed uploads
   ./migrate.sh --force upload
   ```

### Progress Monitoring

The migration tool maintains detailed logs and progress information:

1. Log Files:
   ```
   logs/
   ├── download/           # Download phase logs per account
   ├── upload/            # Upload phase logs per account
   └── migration.log      # Main migration log
   ```

2. Statistics:
   ```
   stats/
   ├── accounts/          # Per-account state information
   ├── progress/          # Progress tracking data
   └── validation/        # Validation results
   ```

3. Message Storage:
   ```
   messages/
   └── user@domain/       # Downloaded messages per account
       ├── Inbox/
       ├── Sent Items/
       └── [Other folders]/
   ```

### Error Handling

The migration tool provides robust error handling and recovery:

1. Download Errors:
   - Rate limiting handled automatically
   - Failed downloads retried automatically
   - Progress preserved on interruption
   - Resume capability from last position

2. Upload Errors:
   - Duplicate prevention
   - MIME format validation
   - Message integrity checks
   - Folder existence verification

3. Recovery Options:
   ```bash
   # Resume interrupted process
   ./migrate.sh --resume download
   ./migrate.sh --resume upload

   # Force retry of failed items
   ./migrate.sh --force download
   ./migrate.sh --force upload

   # Reset and start fresh
   ./migrate.sh --reset download
   ./migrate.sh --reset upload
   ```
## Troubleshooting

### Common Issues

1. Azure Authentication:
   ```
   Error: Failed to acquire token
   Solution:
   - Verify client_id and client_secret in system_config.yaml
   - Check Azure AD application permissions
   - Ensure admin consent is granted
   ```

2. Rate Limiting:
   ```
   Error: ApplicationThrottled
   Solution:
   - Reduce max_parallel_downloads in configuration
   - Increase request_delay value
   - Wait for automatic retry
   ```

3. IMAP Upload:
   ```
   Error: IMAP authentication failed
   Solution:
   - Verify Modoboa server settings
   - Check account credentials
   - Ensure SSL/TLS is properly configured
   ```

4. Permission Issues:
   ```
   Error: Incorrect permissions on config file
   Solution:
   - chmod 600 config/*.yaml
   - chmod 700 config/
   - chmod 755 logs/ stats/ messages/
   ```

### Best Practices

1. Security:
   - Keep configuration files secure
   - Regularly rotate credentials
   - Use separate Azure AD application for migration
   - Clean up sensitive data after migration

2. Performance:
   - Adjust parallel processing based on server capacity
   - Monitor rate limiting and adjust delays
   - Schedule migrations during off-peak hours
   - Process accounts in smaller batches

3. Validation:
   - Verify message counts before and after
   - Check folder structures
   - Validate MIME formats
   - Monitor error logs

4. Maintenance:
   - Regular log rotation
   - Cleanup temporary files
   - Monitor disk space
   - Update Azure credentials before expiration

## Limitations

1. Message Types:
   - Standard email messages supported
   - Calendar items not migrated
   - Contacts not migrated
   - Tasks not migrated

2. Account Features:
   - Basic IMAP folders supported
   - Custom folder permissions not preserved
   - Outlook rules not migrated
   - Out-of-office settings not migrated

3. Technical Limits:
   - MS365 API rate limits apply
   - Message size limits based on Modoboa configuration
   - Folder depth limitations based on IMAP support
   - Concurrent processing limits for stability

4. Requirements:
   - Modern Authentication required for MS365
   - Azure AD Application registration required
   - SSL/TLS required for all connections
   - Sufficient disk space for message storage

## Contributing

Contributions are welcome! Please follow these steps:

1. Fork the repository
2. Create a feature branch
3. Commit your changes
4. Push to the branch
5. Create a Pull Request

### Guidelines

- Follow existing code style
- Add tests for new features
- Update documentation
- Maintain security standards
- Don't commit configuration files
- Don't include credentials or PII

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Acknowledgments

- Microsoft Graph API Documentation
- Modoboa Project
- Azure AD Authentication Libraries
- OpenSSL Project

## Support

For issues and feature requests:
1. Check existing issues
2. Provide detailed error messages
3. Include log snippets (sanitized)
4. Describe reproduction steps

For security issues:
- Report privately to maintainers
- Do not post credentials or tokens
- Follow responsible disclosure
