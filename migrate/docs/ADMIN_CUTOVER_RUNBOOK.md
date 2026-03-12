# Email Migration Admin Cutover Runbook

## Pre-Migration Phase (1-2 Weeks Before)

### 1. Google Workspace Setup

#### 1.1 Enable IMAP for All Users
1. Sign in to Google Admin console (admin.google.com)
2. Go to **Apps → Google Workspace → Gmail → End User Access**
3. Enable **IMAP access** for all organizational units
4. Save changes and wait 24 hours for propagation

#### 1.2 Generate App Passwords for Each User

**Option A: Users Generate Their Own (Recommended for Security)**
1. Send instructions to users:
   - Go to https://myaccount.google.com/security
   - Enable 2-Step Verification if not already enabled
   - Go to https://myaccount.google.com/apppasswords
   - Generate an app password for "Mail"
   - Save the 16-character password securely

**Option B: Admin Uses Service Account (Enterprise)**
1. Create a service account with domain-wide delegation
2. Grant necessary OAuth scopes for IMAP access
3. Use service account to authenticate migrations

#### 1.3 Verify Domain Ownership
1. Go to Google Admin → Account → Domains → Manage domains
2. Add your domain if not already added
3. Verify ownership via:
   - TXT record: `google-site-verification=xxxxx`
   - Or HTML file upload
4. Wait for verification (usually 5-30 minutes)

### 2. DNS Preparation (Do NOT Change MX Yet!)

#### 2.1 Document Current MX Records
```bash
# Save current MX records
dig MX example.com > mx_backup_$(date +%Y%m%d).txt
```

Current HostGator MX (example):
```
Priority 0: mail.example.com
```

#### 2.2 Prepare Google MX Records (Do NOT Apply Yet)
```
Priority 1:  aspmx.l.google.com
Priority 5:  alt1.aspmx.l.google.com
Priority 5:  alt2.aspmx.l.google.com
Priority 10: alt3.aspmx.l.google.com
Priority 10: alt4.aspmx.l.google.com
```

#### 2.3 Lower TTL Values
1. 48 hours before cutover, reduce MX TTL to 300 seconds (5 minutes)
2. This allows faster propagation during cutover

### 3. Create Migration CSV

1. Copy the template:
```bash
cp migrate/config/migration_map_template.csv migration_map.csv
```

2. Edit with actual user credentials:
```csv
src_user,src_pass,dst_user,dst_pass
admin@example.com,HOSTGATOR_PASS_HERE,admin@example.com,GOOGLE_APP_PASS_HERE
user4@example.com,HOSTGATOR_PASS_HERE,user4@example.com,GOOGLE_APP_PASS_HERE
```

3. Secure the file:
```bash
chmod 600 migration_map.csv
```

## Migration Phase

### 4. Initial Bulk Migration (1 Week Before Cutover)

#### 4.1 Test Single User
```bash
cd migrate/scripts
./test_single.sh
```

#### 4.2 Run Full Migration
```bash
# Dry run first
./run_batch.sh ../migration_map.csv --dry-run

# Actual migration
./run_batch.sh ../migration_map.csv -c 3 -b 10
```

#### 4.3 Monitor Progress
- Check logs in `migrate/logs/batch_*/`
- Review report in `migrate/reports/`
- Address any failed migrations

### 5. Daily Incremental Syncs (Leading to Cutover)

Run daily to minimize final delta:
```bash
./run_batch.sh ../migration_map.csv -c 2
```

## Cutover Phase

### 6. Cutover Window (Schedule 2-4 Hours)

#### 6.1 Final Pre-Cutover Sync (T-1 Hour)
```bash
# Last sync before MX change
./run_batch.sh ../migration_map.csv -c 4
```

#### 6.2 Configure Google Split Delivery (T-30 Minutes)

This ensures mail continues flowing to old server during transition:

Note: Gmail routing rules evaluate the SMTP envelope recipient (RCPT TO), not the message header "To:" or "Cc:". When debugging, always confirm the envelope recipient in Email Log Search.

1. Go to Google Admin → Apps → Google Workspace → Gmail → Hosts
2. Add host route:
   - **Name**: Legacy HostGator
   - **Host**: mail.example.com
   - **Port**: 25
   - **Options**: TLS required

3. Go to Gmail → Routing
4. Add routing rule:
   - **Name**: Route Unknown Recipients to Legacy
   - **Condition**: Recipient address doesn't match any G Suite user
   - **Action**: Route to Legacy HostGator host
   - **Options**: Also route if user exists but mailbox not created

#### 6.3 Change MX Records (T-0)

1. Log into your DNS provider
2. Delete old MX records
3. Add Google MX records:
```
Priority 1:  aspmx.l.google.com
Priority 5:  alt1.aspmx.l.google.com
Priority 5:  alt2.aspmx.l.google.com
Priority 10: alt3.aspmx.l.google.com
Priority 10: alt4.aspmx.l.google.com
```

4. Verify changes:
```bash
# Check propagation
dig MX example.com @8.8.8.8
dig MX example.com @1.1.1.1
```

#### 6.4 Update SPF Record
```
"v=spf1 include:_spf.google.com include:sendgrid.net include:_spf.reamaze.com ~all"
<!-- TODO: Verify HostGator/other sender includes before cutover -->
```

After verification, remove old host:
```
"v=spf1 include:_spf.google.com ~all"
```

#### 6.5 Run Final Delta Sync (T+30 Minutes)
```bash
# Capture any messages that arrived during cutover
./final_delta.sh ../migration_map.csv -c 2 -a 2

# For VIP users, run immediately:
./final_delta.sh ../migration_map.csv -p "admin@example.com,user4@example.com" -a 1
```

### 7. Verification

#### 7.1 Test Mail Flow
```bash
# Send test email from external account
echo "Test after cutover" | mail -s "MX Test $(date)" test@example.com

# Check delivery
# Should arrive in Gmail, not old server
```

#### 7.2 Monitor Google Admin Reports
1. Go to Admin console → Reports → Email Log Search
2. Filter by last hour
3. Verify incoming mail delivery

#### 7.3 Check Split Delivery
1. Send email to non-existent address
2. Verify it routes to legacy server (if configured)

## Post-Cutover Phase

### 8. First 24 Hours

#### 8.1 Run Delta Syncs Every 6 Hours
```bash
# Catch any stragglers
./final_delta.sh ../migration_map.csv -a 1
```

#### 8.2 Monitor for Issues
- Check user reports
- Review bounce messages
- Monitor mail queues

### 9. Cleanup (After 48-72 Hours)

#### 9.1 Remove Split Delivery
1. Go to Gmail → Routing
2. Delete the "Route Unknown Recipients" rule
3. Delete the Legacy host entry

#### 9.2 Disable Legacy Server Access
1. Change passwords on old server
2. Firewall off IMAP/POP ports
3. Keep server running for 30 days (backup)

#### 9.3 Update Documentation
- Remove old mail server from documentation
- Update user guides for Gmail
- Archive migration logs

### 10. Optional: Clean Migration Artifacts

After confirming everything works:
```bash
# Archive logs
tar -czf migration_logs_$(date +%Y%m%d).tar.gz migrate/logs/
mv migration_logs_*.tar.gz /backup/

# Remove sensitive CSV
shred -u migration_map.csv
```

## Rollback Plan (If Needed)

### Emergency Rollback Steps

1. **Revert MX Records**
```bash
# Change MX back to original
Priority 0: mail.example.com
```

2. **Run Reverse Sync** (Gmail → HostGator)
```bash
# Swap source and destination in CSV
# Run imapsync in reverse
```

3. **Notify Users**
- Send emergency communication
- Provide temporary workarounds

## Common Issues and Solutions

### Issue: Gmail Rate Limiting
**Solution**: Reduce concurrency to 1-2 workers

### Issue: "All Mail" Duplication
**Solution**: Already excluded in scripts, verify with:
```bash
grep "exclude.*Gmail" migrate/scripts/imapsync_cmd.sh
```

### Issue: Authentication Failures
**Solution**:
- Verify 2FA enabled for app passwords
- Check IMAP enabled in Gmail
- Verify no security blocks in Google Admin

### Issue: Missing Folders
**Solution**: Run with --automap flag (already in scripts)

### Issue: DNS Not Propagating
**Solution**:
- Use multiple DNS servers to check
- Clear local DNS cache
- Wait up to 48 hours for global propagation

## Support Contacts

- Google Workspace Support: 1-866-2-GOOGLE
- DNS Provider Support: [Your provider]
- Legacy Host Support: [HostGator details]

## Checklist Summary

### Pre-Migration
- [ ] IMAP enabled in Gmail
- [ ] App passwords generated
- [ ] Domain verified in Google
- [ ] Migration CSV created
- [ ] Test migration successful
- [ ] DNS TTL lowered

### During Cutover
- [ ] Final sync completed
- [ ] Split delivery configured
- [ ] MX records changed
- [ ] SPF record updated
- [ ] Delta sync run
- [ ] Mail flow tested

### Post-Cutover
- [ ] 24-hour delta syncs running
- [ ] Users notified
- [ ] Split delivery removed (after 48h)
- [ ] Legacy server disabled (after verification)
- [ ] Documentation updated

## Notes

- Keep this runbook updated with lessons learned
- Document any custom configurations
- Save all commands run during migration
- Maintain backups for at least 90 days
