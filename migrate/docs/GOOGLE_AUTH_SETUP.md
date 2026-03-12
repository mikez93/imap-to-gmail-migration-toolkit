# Google Authentication Setup for Migration

## Authentication Methods Comparison

| Method | Pros | Cons | Best For |
|--------|------|------|----------|
| App Passwords | Most secure | Each user must generate | Small teams (<10 users) |
| Less Secure Apps | Admin can use regular passwords | Less secure, temporary only | Quick migrations |
| Service Account | Fully automated, no user involvement | Complex setup | Large organizations |
| Admin Password Reset | Admin controls everything | Security risk, disruptive | Emergency migrations |

## Method 1: App Passwords (Individual Users)

### If Users Must Generate Their Own:

1. **Send this instruction email to users:**
```
Subject: Action Required: Generate Email Migration Password

Please generate a temporary password for email migration:

1. Go to: https://myaccount.google.com/security
2. Click "2-Step Verification" → Turn ON (if not already)
3. Go to: https://myaccount.google.com/apppasswords
4. Select "Mail" and "Other (Custom name)"
5. Enter: "Email Migration"
6. Click "Generate"
7. Copy the 16-character password (remove spaces)
8. Send to IT: [your secure collection method]

Example: "abcd efgh ijkl mnop" becomes "abcdefghijklmnop"
```

### Collecting App Passwords Securely:
```bash
# Option A: Encrypted form
# Use Google Forms with restricted access

# Option B: Secure spreadsheet
# Google Sheets with view-once permissions

# Option C: Password manager
# Shared vault in 1Password/Bitwarden
```

## Method 2: Less Secure Apps (Admin Controlled)

### Enable for Migration Period:

1. **Enable in Admin Console:**
```
Admin Console → Security → Basic settings
→ Less secure apps → "Allow users to manage their access"
```

2. **Per-user setup via Admin SDK:**
```python
# Script to enable less secure apps for all users
import csv
from google.oauth2 import service_account
from googleapiclient.discovery import build

# This would enable less secure access programmatically
# (Requires Admin SDK API enabled)
```

3. **For each user in Admin Console:**
- Go to Users → [Select User] → Security
- Turn OFF "2-Step Verification" temporarily
- User Settings → "Allow less secure apps: ON"

4. **Use regular passwords in CSV:**
```csv
src_user,src_pass,dst_user,dst_pass
admin@example.com,HOSTGATOR_PASS_HERE,admin@example.com,GOOGLE_APP_PASS_HERE
```

5. **After migration, re-secure:**
```bash
# Disable less secure apps
# Re-enable 2FA
# Force password reset if needed
```

## Method 3: Admin Password Reset (Quick & Dirty)

**⚠️ WARNING: Disruptive to users!**

1. **Bulk reset all passwords:**
```python
#!/usr/bin/env python3
# bulk_password_reset.py

import csv
import random
import string
from google.oauth2 import service_account
from googleapiclient.discovery import build

def generate_password():
    """Generate a secure temporary password"""
    return ''.join(random.choices(
        string.ascii_letters + string.digits,
        k=16
    ))

def reset_passwords(admin_email, users_csv):
    """Reset passwords for all users in CSV"""

    # Initialize Admin SDK
    SCOPES = ['https://www.googleapis.com/auth/admin.directory.user']
    creds = service_account.Credentials.from_service_account_file(
        'service-account-key.json',
        scopes=SCOPES,
        subject=admin_email
    )

    service = build('admin', 'directory_v1', credentials=creds)

    # Reset passwords
    with open(users_csv, 'r') as infile, \
         open('passwords.csv', 'w') as outfile:

        reader = csv.DictReader(infile)
        writer = csv.writer(outfile)
        writer.writerow(['email', 'temp_password'])

        for row in reader:
            email = row['dst_user']
            temp_pass = generate_password()

            # Reset via API
            service.users().update(
                userKey=email,
                body={'password': temp_pass}
            ).execute()

            writer.writerow([email, temp_pass])
            print(f"Reset: {email}")

    print("Passwords saved to passwords.csv")

# Usage
reset_passwords('admin@example.com', 'users.csv')
```

## Method 4: OAuth 2.0 Service Account (Best for Large Scale)

### Setup Service Account:

1. **Create Service Account:**
```bash
# In Google Cloud Console
1. Go to: console.cloud.google.com
2. Create new project or select existing
3. Enable Admin SDK API
4. Create Service Account:
   - Name: "Email Migration Service"
   - Role: "Project Editor"
   - Create key (JSON)
```

2. **Enable Domain-Wide Delegation:**
```
Admin Console → Security → API controls
→ Domain-wide delegation → Add new
→ Client ID: [from service account]
→ Scopes:
   https://mail.google.com/
   https://www.googleapis.com/auth/admin.directory.user
```

3. **Modified imapsync wrapper for OAuth:**
```bash
#!/bin/bash
# oauth_imapsync.sh

# Get OAuth token for user
get_oauth_token() {
    local user_email=$1
    python3 get_oauth_token.py "$user_email"
}

# Use with imapsync
TOKEN=$(get_oauth_token "admin@example.com")

imapsync \
    --host2 imap.gmail.com \
    --user2 "admin@example.com" \
    --authuser2 "admin@example.com" \
    --authmech2 XOAUTH2 \
    --password2 "$TOKEN" \
    ...
```

## Simplified Approach for Your Situation

Since you don't have Enterprise and are doing this yourself:

### Recommended Process:

1. **Create a test Google Workspace account**
2. **For the test account:**
   - Enable 2FA
   - Generate app password
   - Test with: `abcdefghijklmnop` (no spaces)

3. **For production migration:**

```bash
# Option A: Collect passwords yourself
# Create a secure form for users to submit app passwords

# Option B: Temporary less secure access
# 1. Disable 2FA for migration week
# 2. Enable "less secure apps"
# 3. Use regular passwords
# 4. Re-secure after migration

# Option C: Reset passwords yourself
# 1. Reset all passwords to temporary ones
# 2. Run migration
# 3. Force password change on first login
```

### Quick Collection Script:

```bash
#!/bin/bash
# collect_app_passwords.sh

echo "App Password Collection Tool"
echo "============================"

CSV_FILE="migration_map.csv"
echo "src_user,src_pass,dst_user,dst_pass" > "$CSV_FILE"

while true; do
    read -p "Source email: " src_email
    read -sp "Source password: " src_pass
    echo
    read -p "Destination email: " dst_email
    echo "Get app password from: https://myaccount.google.com/apppasswords"
    read -p "Enter app password (no spaces): " dst_pass

    echo "$src_email,$src_pass,$dst_email,$dst_pass" >> "$CSV_FILE"

    read -p "Add another user? (y/n): " continue
    if [[ "$continue" != "y" ]]; then
        break
    fi
done

echo "Saved to $CSV_FILE"
chmod 600 "$CSV_FILE"
```

## Testing Authentication:

```bash
# Test Google authentication directly
imapsync \
    --host2 imap.gmail.com \
    --user2 "admin@example.com" \
    --password2 "apppasswordnoSpaces" \
    --ssl2 \
    --justlogin

# If it works, you'll see:
# "Host2: success login on [imap.gmail.com] as [admin@example.com]"
```

## Decision Matrix:

For your situation (non-Enterprise, admin-controlled migration):

1. **Less than 10 users?** → Reset passwords temporarily
2. **10-50 users?** → Enable less secure apps temporarily
3. **50+ users?** → Set up service account with OAuth
4. **Security critical?** → Have users generate app passwords

The simplest approach: **Enable less secure apps for migration week, use regular passwords, then re-secure everything.**
