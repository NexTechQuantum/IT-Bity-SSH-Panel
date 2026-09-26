// Settings Page JavaScript

document.addEventListener('DOMContentLoaded', function() {
    setupEventListeners();
    loadSettings();
});

function setupEventListeners() {
    // Toggle switches
    const toggles = document.querySelectorAll('.toggle-switch input');
    toggles.forEach(toggle => {
        toggle.addEventListener('change', handleToggleChange);
    });
    
    // File upload
    const fileInput = document.getElementById('fileInput');
    if (fileInput) {
        fileInput.addEventListener('change', handleFileSelect);
    }
    
    // Drag and drop
    const uploadZone = document.getElementById('uploadZone');
    if (uploadZone) {
        uploadZone.addEventListener('dragover', handleDragOver);
        uploadZone.addEventListener('drop', handleFileDrop);
        uploadZone.addEventListener('dragleave', handleDragLeave);
    }
}

function handleToggleChange(e) {
    const toggleId = e.target.id;
    const isChecked = e.target.checked;
    
    console.log(`Toggle ${toggleId} changed to: ${isChecked}`);
    
    if (toggleId === 'userPanelAccess') {
        saveUserPanelAccess(isChecked);
        return;
    }

    // Special handling for 2FA enforce
    if (toggleId === 'enable2FA') {
        const enforce2FA = document.getElementById('enforce2FA');
        if (enforce2FA) {
            enforce2FA.disabled = !isChecked;
        }
    }
    
    // TODO: Save setting to backend
    showNotification('Setting updated', 'success');
}

async function loadSettings() {
    try {
        const response = await fetch('api/user-panel/status', { headers: { Accept: 'application/json' } });
        const data = await response.json();
        if (!response.ok || !data.success) throw new Error(data.message || 'Unable to load user panel setting');
        updateUserPanelControl(Boolean(data.enabled));
        await loadRecommendedApps();
    } catch (error) {
        showNotification(error.message, 'error');
    }
    await loadBackupStatus();
    try {
        const response = await fetch('api/ssh/config', { headers: { Accept: 'application/json' } });
        const data = await response.json();
        if (!response.ok || !data.success) throw new Error(data.message || 'Unable to load SSH settings');
        document.getElementById('encryptionType').value = data.profile || 'automatic';
    } catch (error) {
        showNotification(error.message, 'error');
    }
    try {
        const response = await fetch('api/wireguard/config', { headers: { Accept: 'application/json' } });
        const data = await response.json();
        if (!response.ok || !data.success) throw new Error(data.message || 'Unable to load WireGuard settings');
        document.getElementById('sshUDP').checked = Boolean(data.enabled);
        document.getElementById('wireguardEndpoint').value = data.endpoint || '';
        document.getElementById('wireguardPort').value = data.port || 51820;
        document.getElementById('wireguardStatus').textContent = data.running ? 'Running' : 'Stopped';
    } catch (error) {
        showNotification(error.message, 'error');
    }
}

// SSL Functions
function installSSL() {
    alert('SSL Installation - Coming soon!\n\nThis will:\n- Request SSL certificate\n- Configure web server\n- Enable HTTPS');
    // TODO: Implement SSL installation
}

// SSH Configuration
async function saveSSHConfig() {
    const profile = document.getElementById('encryptionType').value;
    const button = document.getElementById('saveSSHButton');
    button.disabled = true;
    try {
        const response = await fetch('api/ssh/config', {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
            body: JSON.stringify({ profile }),
        });
        const data = await response.json();
        if (!response.ok || !data.success) throw new Error(data.message || 'SSH validation failed');
        showNotification('SSH profile validated and applied', 'success');
        await loadSettings();
    } catch (error) {
        showNotification(error.message, 'error');
    } finally {
        button.disabled = false;
    }
}

async function loadRecommendedApps() {
    const response = await fetch('api/user-panel/apps', { headers: { Accept: 'application/json' } });
    const data = await response.json();
    if (!response.ok || !data.success) throw new Error(data.message || 'Unable to load applications');
    const list = document.getElementById('recommendedAppsList');
    list.innerHTML = data.apps.length ? data.apps.map(app => `<div style="display:flex;align-items:center;gap:8px;padding:9px 11px;background:var(--bg-secondary);border-radius:8px;font-size:12px;"><i class="fas fa-mobile-screen"></i><strong>${escapeSettingHtml(app.name)}</strong><span style="color:var(--text-secondary);flex:1;">${escapeSettingHtml(app.platform)}</span><button type="button" class="btn-action delete" onclick="deleteRecommendedApp(${app.id})"><i class="fas fa-trash"></i></button></div>`).join('') : '<span class="setting-desc">No applications added yet.</span>';
}

async function addRecommendedApp() {
    const payload = {name: document.getElementById('recommendedAppName').value.trim(), platform: document.getElementById('recommendedAppPlatform').value.trim(), download_url: document.getElementById('recommendedAppUrl').value.trim()};
    const response = await fetch('api/user-panel/apps', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)});
    const data = await response.json();
    if (!response.ok || !data.success) return showNotification(data.message || 'Unable to add application', 'error');
    ['recommendedAppName','recommendedAppPlatform','recommendedAppUrl'].forEach(id => document.getElementById(id).value = '');
    await loadRecommendedApps();
    showNotification('Application added', 'success');
}

async function deleteRecommendedApp(appId) {
    const response = await fetch(`api/user-panel/apps/${appId}`, {method:'DELETE'});
    if (!response.ok) return showNotification('Unable to delete application', 'error');
    await loadRecommendedApps();
}

function escapeSettingHtml(value) {
    const element = document.createElement('div');
    element.textContent = value;
    return element.innerHTML;
}

async function saveUserPanelAccess(enabled) {
    const toggle = document.getElementById('userPanelAccess');
    toggle.disabled = true;
    try {
        const response = await fetch('api/user-panel/toggle', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
            body: JSON.stringify({ enabled }),
        });
        const data = await response.json();
        if (!response.ok || !data.success) throw new Error(data.message || 'Unable to update user panel');
        updateUserPanelControl(Boolean(data.enabled));
        showNotification(`User panel ${data.enabled ? 'enabled' : 'disabled'}`, 'success');
    } catch (error) {
        toggle.checked = !enabled;
        showNotification(error.message, 'error');
    } finally {
        toggle.disabled = false;
    }
}

function updateUserPanelControl(enabled) {
    document.getElementById('userPanelAccess').checked = enabled;
    const badge = document.getElementById('userPanelBadge');
    badge.classList.toggle('active', enabled);
    badge.classList.toggle('inactive', !enabled);
    badge.innerHTML = `<i class="fas fa-circle"></i> ${enabled ? 'Active' : 'Disabled'}`;
}

async function saveWireGuardConfig() {
    const button = document.getElementById('saveWireGuardButton');
    const enabled = document.getElementById('sshUDP').checked;
    const endpoint = document.getElementById('wireguardEndpoint').value.trim();
    const port = Number(document.getElementById('wireguardPort').value);
    if (!endpoint) return showNotification('Enter the public server IP or hostname', 'error');
    button.disabled = true;
    try {
        const response = await fetch('api/wireguard/config', {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
            body: JSON.stringify({ enabled, endpoint, port }),
        });
        const data = await response.json();
        if (!response.ok || !data.success) throw new Error(data.message || 'WireGuard configuration failed');
        showNotification(`WireGuard ${enabled ? 'enabled' : 'disabled'}`, 'success');
        await loadSettings();
    } catch (error) {
        showNotification(error.message, 'error');
    } finally {
        button.disabled = false;
    }
}

// File Upload Functions
function handleFileSelect(e) {
    const file = e.target.files[0];
    if (file) {
        uploadFile(file);
    }
}

function handleDragOver(e) {
    e.preventDefault();
    e.stopPropagation();
    e.currentTarget.style.borderColor = 'var(--primary)';
    e.currentTarget.style.background = 'rgba(79, 70, 229, 0.05)';
}

function handleDragLeave(e) {
    e.preventDefault();
    e.stopPropagation();
    e.currentTarget.style.borderColor = 'var(--border)';
    e.currentTarget.style.background = 'transparent';
}

function handleFileDrop(e) {
    e.preventDefault();
    e.stopPropagation();
    
    const uploadZone = e.currentTarget;
    uploadZone.style.borderColor = 'var(--border)';
    uploadZone.style.background = 'transparent';
    
    const file = e.dataTransfer.files[0];
    if (file) {
        if (file.name.endsWith('.zip')) {
            uploadFile(file);
        } else {
            alert('Please upload a ZIP file');
        }
    }
}

function uploadFile(file) {
    console.log('Uploading file:', file.name);
    
    // Show upload progress (mock)
    const uploadZone = document.getElementById('uploadZone');
    const originalContent = uploadZone.innerHTML;
    
    uploadZone.innerHTML = `
        <i class="fas fa-spinner fa-spin"></i>
        <p>Uploading ${file.name}...</p>
        <div style="width: 80%; height: 8px; background: var(--border); border-radius: 4px; margin: 16px auto;">
            <div id="uploadProgress" style="width: 0%; height: 100%; background: var(--primary); border-radius: 4px; transition: width 0.3s;"></div>
        </div>
    `;
    
    // Simulate upload progress
    let progress = 0;
    const interval = setInterval(() => {
        progress += 10;
        const progressBar = document.getElementById('uploadProgress');
        if (progressBar) {
            progressBar.style.width = progress + '%';
        }
        
        if (progress >= 100) {
            clearInterval(interval);
            setTimeout(() => {
                uploadZone.innerHTML = originalContent;
                showNotification('File uploaded successfully', 'success');
            }, 500);
        }
    }, 200);
    
    // TODO: Implement actual file upload
}

// Telegram backup
async function loadBackupStatus() {
    try {
        const response = await fetch('api/backup/status', {headers:{Accept:'application/json'}});
        const data = await response.json();
        if (!response.ok || !data.success) throw new Error(data.message || 'Unable to load backup settings');
        document.getElementById('backupSchedule').value = data.schedule || '02:00';
        document.getElementById('backupChatId').value = data.chat_id || '';
        const badge = document.getElementById('backupStatusBadge');
        badge.classList.toggle('active', data.configured);
        badge.classList.toggle('inactive', !data.configured);
        badge.innerHTML = `<i class="fas fa-circle"></i> ${data.configured ? 'Scheduled' : 'Not configured'}`;
        const size = data.last_size ? ` · ${formatBytes(data.last_size)}` : '';
        const result = data.running ? 'Running…' : data.last_success === true ? 'Successful' : data.last_success === false ? `Failed: ${escapeSettingHtml(data.last_error || '')}` : 'Never';
        document.getElementById('backupLastRun').innerHTML = `<small><i class="fas fa-info-circle"></i> Last backup: ${data.last_run ? new Date(data.last_run).toLocaleString() : 'Never'} · ${result}${size}</small>`;
    } catch (error) {
        showNotification(error.message, 'error');
    }
}

async function saveBackupConfig() {
    const button = document.getElementById('saveBackupButton');
    button.disabled = true;
    try {
        const response = await fetch('api/backup/config', {method:'PUT',headers:{'Content-Type':'application/json'},body:JSON.stringify({schedule:document.getElementById('backupSchedule').value,chat_id:document.getElementById('backupChatId').value.trim(),token:document.getElementById('backupToken').value.trim()})});
        const data = await response.json();
        if (!response.ok || !data.success) throw new Error(data.message || 'Unable to save backup settings');
        document.getElementById('backupToken').value = '';
        showNotification('Backup schedule saved', 'success');
        await loadBackupStatus();
    } catch (error) { showNotification(error.message, 'error'); }
    finally { button.disabled = false; }
}

async function testBackupConnection() {
    await runBackupAction('testBackupButton', 'api/backup/test', 'Telegram test message sent');
}

async function createBackup() {
    if (!confirm('Create and send a full backup to the configured Telegram channel now?')) return;
    await runBackupAction('runBackupButton', 'api/backup/create', 'Full backup started in background');
    await loadBackupStatus();
}

async function runBackupAction(buttonId, endpoint, successMessage) {
    const button = document.getElementById(buttonId);
    button.disabled = true;
    const old = button.innerHTML;
    button.innerHTML = '<i class="fas fa-spinner fa-spin"></i> Working…';
    try {
        const response = await fetch(endpoint, {method:'POST'});
        const data = await response.json();
        if (!response.ok || !data.success) throw new Error(data.message || 'Backup operation failed');
        showNotification(successMessage, 'success');
    } catch (error) { showNotification(error.message, 'error'); }
    finally { button.disabled = false; button.innerHTML = old; }
}

function toggleBackupToken() {
    const input = document.getElementById('backupToken');
    input.type = input.type === 'password' ? 'text' : 'password';
}

function formatBytes(bytes) {
    if (!bytes) return '0 B';
    const units = ['B','KB','MB','GB'];
    const index = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1);
    return `${(bytes / Math.pow(1024, index)).toFixed(index ? 1 : 0)} ${units[index]}`;
}

// Notification Helper
function showNotification(message, type = 'info') {
    // Create notification element
    const notification = document.createElement('div');
    notification.className = `notification notification-${type}`;
    notification.innerHTML = `
        <i class="fas fa-${type === 'success' ? 'check-circle' : 'info-circle'}"></i>
        <span>${message}</span>
    `;
    
    // Add styles
    notification.style.cssText = `
        position: fixed;
        top: 80px;
        right: 20px;
        background: ${type === 'success' ? '#10b981' : type === 'error' ? '#ef4444' : '#3b82f6'};
        color: white;
        padding: 14px 20px;
        border-radius: 10px;
        box-shadow: 0 4px 12px rgba(0,0,0,0.15);
        display: flex;
        align-items: center;
        gap: 10px;
        z-index: 10000;
        animation: slideIn 0.3s ease;
    `;
    
    document.body.appendChild(notification);
    
    // Remove after 3 seconds
    setTimeout(() => {
        notification.style.animation = 'slideOut 0.3s ease';
        setTimeout(() => {
            document.body.removeChild(notification);
        }, 300);
    }, 3000);
}

// Add CSS animations
const style = document.createElement('style');
style.textContent = `
    @keyframes slideIn {
        from {
            transform: translateX(100%);
            opacity: 0;
        }
        to {
            transform: translateX(0);
            opacity: 1;
        }
    }
    
    @keyframes slideOut {
        from {
            transform: translateX(0);
            opacity: 1;
        }
        to {
            transform: translateX(100%);
            opacity: 0;
        }
    }
`;
document.head.appendChild(style);
