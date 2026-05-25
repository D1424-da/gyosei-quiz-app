/* =========================================================
   肢別問題集 - auth-module.js
   Firebase Authentication and admin overlay helpers
   ========================================================= */

(function () {
  let localAdminAuthenticated = false;

  function byId(id) {
    return document.getElementById(id);
  }

  function hasFirebaseAuth() {
    return !!(window.firebase && typeof firebase.auth === 'function');
  }

  function getAuth() {
    if (!hasFirebaseAuth()) return null;
    try {
      return firebase.auth();
    } catch {
      return null;
    }
  }

  function isFileProtocol() {
    return typeof window !== 'undefined' && window.location?.protocol === 'file:';
  }

  function setVisible(el, visible) {
    if (!el) return;
    el.classList.toggle('hidden', !visible);
  }

  function setError(id, message) {
    const el = byId(id);
    if (!el) return;
    if (message) {
      el.textContent = message;
      el.classList.remove('hidden');
    } else {
      el.textContent = '';
      el.classList.add('hidden');
    }
  }

  function clearAuthErrors() {
    setError('login-error', '');
    setError('reg-error', '');
    setError('reset-error', '');
    const ok = byId('reset-success');
    if (ok) ok.classList.add('hidden');
  }

  function getUserLabel(user) {
    if (!user) return '';
    return user.displayName || user.email || 'ユーザー';
  }

  function showAppAsGuest() {
    const app = byId('app');
    const overlay = byId('login-overlay');
    const name = byId('current-user-name');
    if (app) app.classList.remove('hidden');
    if (overlay) overlay.classList.add('hidden');
    if (name) name.textContent = 'ゲスト';
  }

  function applySignedIn(user) {
    window.currentUser = user
      ? {
          uid: user.uid,
          email: user.email || '',
          displayName: user.displayName || user.email || ''
        }
      : null;

    if (typeof hideLoginOverlay === 'function') {
      hideLoginOverlay();
    } else {
      const app = byId('app');
      const overlay = byId('login-overlay');
      const name = byId('current-user-name');
      if (app) app.classList.remove('hidden');
      if (overlay) overlay.classList.add('hidden');
      if (name) name.textContent = getUserLabel(window.currentUser);
    }
  }

  function applySignedOut() {
    window.currentUser = null;
    localAdminAuthenticated = false;

    if (typeof showLoginOverlay === 'function') {
      showLoginOverlay();
    } else {
      const app = byId('app');
      const overlay = byId('login-overlay');
      if (app) app.classList.add('hidden');
      if (overlay) overlay.classList.remove('hidden');
    }

    if (typeof updateMembersOnlyPanels === 'function') {
      updateMembersOnlyPanels();
    }
  }

  function switchAuthForm(form) {
    const loginArea = byId('login-form-area');
    const registerArea = byId('register-form-area');
    const resetArea = byId('reset-form-area');

    setVisible(loginArea, form === 'login');
    setVisible(registerArea, form === 'register');
    setVisible(resetArea, form === 'reset');
    clearAuthErrors();
  }

  async function doEmailLogin() {
    if (isFileProtocol()) {
      setError('login-error', 'file:// ではログインできません。http://localhost で開いてください。');
      return;
    }

    const auth = getAuth();
    if (!auth) {
      setError('login-error', 'Firebase認証が設定されていません。');
      return;
    }

    const email = (byId('login-email')?.value || '').trim();
    const password = byId('login-password')?.value || '';
    if (!email || !password) {
      setError('login-error', 'メールアドレスとパスワードを入力してください。');
      return;
    }

    try {
      setError('login-error', '');
      await auth.signInWithEmailAndPassword(email, password);
    } catch (e) {
      setError('login-error', e?.message || 'ログインに失敗しました。');
    }
  }

  async function doRegister() {
    if (isFileProtocol()) {
      setError('reg-error', 'file:// では新規登録できません。http://localhost で開いてください。');
      return;
    }

    const auth = getAuth();
    if (!auth) {
      setError('reg-error', 'Firebase認証が設定されていません。');
      return;
    }

    const email = (byId('reg-email')?.value || '').trim();
    const pw = byId('reg-password')?.value || '';
    const pw2 = byId('reg-password2')?.value || '';

    if (!email) {
      setError('reg-error', 'メールアドレスを入力してください。');
      return;
    }
    if (pw.length < 6) {
      setError('reg-error', 'パスワードは6文字以上で入力してください。');
      return;
    }
    if (pw !== pw2) {
      setError('reg-error', 'パスワードが一致しません。');
      return;
    }

    try {
      setError('reg-error', '');
      await auth.createUserWithEmailAndPassword(email, pw);
    } catch (e) {
      setError('reg-error', e?.message || 'ユーザー作成に失敗しました。');
    }
  }

  async function doResetPassword() {
    if (isFileProtocol()) {
      setError('reset-error', 'file:// ではパスワードリセットできません。http://localhost で開いてください。');
      return;
    }

    const auth = getAuth();
    if (!auth) {
      setError('reset-error', 'Firebase認証が設定されていません。');
      return;
    }

    const email = (byId('reset-email')?.value || '').trim();
    if (!email) {
      setError('reset-error', 'メールアドレスを入力してください。');
      return;
    }

    try {
      setError('reset-error', '');
      await auth.sendPasswordResetEmail(email);
      const ok = byId('reset-success');
      if (ok) ok.classList.remove('hidden');
    } catch (e) {
      setError('reset-error', e?.message || '送信に失敗しました。');
    }
  }

  async function doGoogleLogin() {
    if (isFileProtocol()) {
      setError('login-error', 'file:// ではGoogleログインできません。http://localhost で開いてください。');
      return;
    }

    const auth = getAuth();
    if (!auth || !firebase.auth?.GoogleAuthProvider) {
      setError('login-error', 'Googleログインを利用できません。');
      return;
    }

    try {
      setError('login-error', '');
      const provider = new firebase.auth.GoogleAuthProvider();
      await auth.signInWithPopup(provider);
    } catch (e) {
      setError('login-error', e?.message || 'Googleログインに失敗しました。');
    }
  }

  async function doLogout() {
    if (typeof window.logout === 'function') {
      try {
        await window.logout();
      } catch {
        // continue to sign out
      }
    }

    const auth = getAuth();
    if (auth && auth.currentUser) {
      try {
        await auth.signOut();
      } catch {
        // ignore
      }
    } else {
      applySignedOut();
    }
  }

  function openAdminLoginOverlay() {
    const overlay = byId('admin-login-overlay');
    const err = byId('admin-login-error');
    const user = byId('admin-login-username');
    const pw = byId('admin-login-password');

    if (err) err.classList.add('hidden');
    if (user) user.value = '';
    if (pw) pw.value = '';
    if (overlay) overlay.classList.remove('hidden');
  }

  function closeAdminLoginOverlay() {
    const overlay = byId('admin-login-overlay');
    if (overlay) overlay.classList.add('hidden');
  }

  function getAdminCredentials() {
    const cfg = window.APP_CONFIG?.adminLogin || {};
    return {
      username: String(cfg.username || 'ikeda.job08@gmail.com').trim(),
      password: String(cfg.password || 'admin1234')
    };
  }

  function doAdminLogin() {
    const creds = getAdminCredentials();
    const username = (byId('admin-login-username')?.value || '').trim();
    const password = byId('admin-login-password')?.value || '';
    const err = byId('admin-login-error');

    if (username === creds.username && password === creds.password) {
      localAdminAuthenticated = true;
      if (err) err.classList.add('hidden');
      closeAdminLoginOverlay();
      if (typeof showPage === 'function') {
        showPage('admin');
      }
      return;
    }

    if (err) {
      err.textContent = '管理者IDまたはパスワードが正しくありません。';
      err.classList.remove('hidden');
    }
  }

  function bindEvents() {
    byId('btn-login')?.addEventListener('click', doEmailLogin);
    byId('btn-register')?.addEventListener('click', doRegister);
    byId('btn-do-reset')?.addEventListener('click', doResetPassword);

    byId('btn-show-register')?.addEventListener('click', () => switchAuthForm('register'));
    byId('btn-show-login')?.addEventListener('click', () => switchAuthForm('login'));
    byId('btn-show-reset')?.addEventListener('click', () => switchAuthForm('reset'));
    byId('btn-show-login-from-reset')?.addEventListener('click', () => switchAuthForm('login'));

    byId('btn-close-login-overlay')?.addEventListener('click', showAppAsGuest);

    byId('btn-logout')?.addEventListener('click', doLogout);
    byId('btn-admin-logout')?.addEventListener('click', () => {
      localAdminAuthenticated = false;
      doLogout();
    });

    byId('btn-admin-login-cancel')?.addEventListener('click', closeAdminLoginOverlay);
    byId('btn-admin-login')?.addEventListener('click', doAdminLogin);

    byId('admin-login-overlay')?.addEventListener('click', (e) => {
      if (e.target === byId('admin-login-overlay')) closeAdminLoginOverlay();
    });

    const googleContainer = byId('google-login-btn');
    if (googleContainer) {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'btn btn-ghost login-submit';
      btn.textContent = 'Googleでログイン';
      btn.addEventListener('click', doGoogleLogin);
      googleContainer.innerHTML = '';
      googleContainer.appendChild(btn);
    }
  }

  function startAuthObserver() {
    const auth = getAuth();
    if (!auth) {
      // Firebase未設定でもゲストで操作開始できるようにする
      showAppAsGuest();
      return;
    }

    auth.onAuthStateChanged((user) => {
      if (user) {
        applySignedIn(user);
      } else {
        applySignedOut();
      }
    });
  }

  window.switchAuthForm = switchAuthForm;
  window.openAdminLoginOverlay = openAdminLoginOverlay;
  window.closeAdminLoginOverlay = closeAdminLoginOverlay;
  window.isLocalAdminAuthenticated = function () {
    return !!localAdminAuthenticated;
  };

  document.addEventListener('DOMContentLoaded', function () {
    bindEvents();
    switchAuthForm('login');
    startAuthObserver();
  });
})();
