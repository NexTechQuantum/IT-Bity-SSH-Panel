const modal = document.getElementById('portalModal');
const modalContent = document.getElementById('portalModalContent');

function openModal(html) { modalContent.innerHTML = html; modal.hidden = false; document.body.style.overflow = 'hidden'; }
function closePortalModal() { modal.hidden = true; modalContent.innerHTML = ''; document.body.style.overflow = ''; }
function escapeHtml(value) { const node = document.createElement('div'); node.textContent = value; return node.innerHTML; }

function openPurchase(action) {
  openModal(`<span class="portal-eyebrow">${action === 'renew' ? 'RENEW SERVICE' : 'CHANGE PLAN'}</span><h2>${action === 'renew' ? 'Renew your subscription' : 'Upgrade your service'}</h2><p>Online purchasing will be connected in the next step. For now, send a support request and the administrator will contact you.</p><button class="portal-primary-button" style="margin-top:18px" onclick="openTicket('${action === 'renew' ? 'Subscription renewal' : 'Plan upgrade'}')"><i class="fas fa-paper-plane"></i> Contact support</button>`);
}

function openTicket(subject = '') {
  openModal(`<span class="portal-eyebrow">SUPPORT</span><h2>New ticket</h2><p>Describe your request and include any useful details.</p><form class="modal-form" onsubmit="submitTicket(event)"><label>Subject<input id="ticketSubject" maxlength="160" value="${escapeHtml(subject)}" required></label><label>Message<textarea id="ticketMessage" minlength="10" maxlength="5000" required></textarea></label><button class="portal-primary-button" type="submit"><i class="fas fa-paper-plane"></i> Submit ticket</button></form>`);
}

async function submitTicket(event) {
  event.preventDefault();
  const response = await fetch(window.userPanelUrls.tickets, {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({subject:document.getElementById('ticketSubject').value,message:document.getElementById('ticketMessage').value})});
  const data = await response.json();
  if (!response.ok || !data.success) return alert(data.message || 'Could not submit ticket');
  closePortalModal(); location.reload();
}

function openPasswordChange() {
  openModal(`<span class="portal-eyebrow">SECURITY</span><h2>Change password</h2><p>This changes both your panel login and SSH password.</p><form class="modal-form" onsubmit="changePassword(event)"><label>Current password<input id="currentPassword" type="password" required autocomplete="current-password"></label><label>New password<input id="newPassword" type="password" minlength="8" required autocomplete="new-password"></label><label>Confirm new password<input id="confirmPassword" type="password" minlength="8" required autocomplete="new-password"></label><button class="portal-primary-button" type="submit"><i class="fas fa-key"></i> Update password</button></form>`);
}

async function changePassword(event) {
  event.preventDefault();
  const next = document.getElementById('newPassword').value;
  if (next !== document.getElementById('confirmPassword').value) return alert('Passwords do not match');
  const response = await fetch(window.userPanelUrls.password,{method:'PUT',headers:{'Content-Type':'application/json'},body:JSON.stringify({current_password:document.getElementById('currentPassword').value,new_password:next})});
  const data = await response.json();
  if (!response.ok || !data.success) return alert(data.message || 'Could not change password');
  openModal('<span class="portal-eyebrow">DONE</span><h2>Password updated</h2><p>Your new password is now active for the panel and SSH connection.</p>');
}

function showWireGuard() {
  openModal(`<span class="portal-eyebrow">WIREGUARD</span><h2>Scan configuration</h2><p>Open WireGuard on your device and scan this QR code.</p><img class="wg-user-qr" src="${window.userPanelUrls.wgQr}" alt="WireGuard QR"><div style="display:flex;gap:9px;justify-content:center"><a class="portal-primary-button" href="${window.userPanelUrls.wgConfig}?download=1"><i class="fas fa-download"></i> Download .conf</a><a class="portal-primary-button" href="${window.userPanelUrls.wgQr}?download=1"><i class="fas fa-qrcode"></i> Download QR</a></div>`);
}

document.addEventListener('keydown', event => { if (event.key === 'Escape') closePortalModal(); });
