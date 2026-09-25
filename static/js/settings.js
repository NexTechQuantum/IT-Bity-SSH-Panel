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
        const response = await fetch('api/ssh/config', { headers: { Accept: 'application/json' } });
        const data = await response.json();
        if (!response.ok || !data.success) throw new Error(data.message || 'Unable to load SSH settings');
        document.getElementById('encryptionType').value = data.profile || 'automatic';
        document.getElementById('sshCompression').checked = Boolean(data.compression);
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
    const compressionEnabled = document.getElementById('sshCompression').checked;
    const button = document.getElementById('saveSSHButton');
    button.disabled = true;
    try {
        const response = await fetch('api/ssh/config', {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
            body: JSON.stringify({ profile, compression: compressionEnabled }),
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

// Backup Functions
function createBackup() {
    const confirmed = confirm('Create a full system backup?\n\nThis will include:\n- Database\n- Configuration files\n- User data');
    
    if (confirmed) {
        alert('Creating backup...\n\nThis feature will be implemented soon!');
        // TODO: Implement backup creation
        showNotification('Backup created successfully', 'success');
    }
}

function restoreBackup() {
    const confirmed = confirm('Restore from backup?\n\n⚠️ WARNING: This will overwrite current data!\n\nAre you sure?');
    
    if (confirmed) {
        alert('Restore from backup...\n\nThis feature will be implemented soon!');
        // TODO: Implement backup restore
    }
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
