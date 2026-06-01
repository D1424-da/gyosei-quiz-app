// Firebase Authentication Module
// Firebase 認証と Firestore データベースの連携

// ===== ユーティリティ関数 =====
function showError(elementId, message) {
  const el = document.getElementById(elementId);
  if (!el) return;
  el.textContent = message;
  el.classList.remove('hidden');
}

function hideError(elementId) {
  const el = document.getElementById(elementId);
  if (!el) return;
  el.classList.add('hidden');
}

function getGoogleClientId() {
  const configured = window.APP_CONFIG?.googleClientId || '';
  return String(configured).trim();
}

const GOOGLE_REDIRECT_PENDING_KEY = 'limb_google_redirect_pending';
const GOOGLE_REDIRECT_PENDING_AT_KEY = 'limb_google_redirect_pending_at';

function setGoogleRedirectPending(enabled) {
  try {
    if (enabled) {
      localStorage.setItem(GOOGLE_REDIRECT_PENDING_KEY, '1');
      localStorage.setItem(GOOGLE_REDIRECT_PENDING_AT_KEY, String(Date.now()));
    } else {
      localStorage.removeItem(GOOGLE_REDIRECT_PENDING_KEY);
      localStorage.removeItem(GOOGLE_REDIRECT_PENDING_AT_KEY);
    }
  } catch {
    // ignore
  }
}

function hasRecentGoogleRedirectPending(maxAgeMs = 10 * 60 * 1000) {
  try {
    if (localStorage.getItem(GOOGLE_REDIRECT_PENDING_KEY) !== '1') return false;
    const at = Number(localStorage.getItem(GOOGLE_REDIRECT_PENDING_AT_KEY) || 0);
    return at > 0 && (Date.now() - at) <= maxAgeMs;
  } catch {
    return false;
  }
}

async function ensureAuthPersistence() {
  const auth = firebase.auth();
  const modes = [
    firebase.auth.Auth.Persistence.LOCAL,
    firebase.auth.Auth.Persistence.SESSION,
    firebase.auth.Auth.Persistence.NONE,
  ];
  for (const mode of modes) {
    try {
      await auth.setPersistence(mode);
      return mode;
    } catch (error) {
      console.warn('Auth persistence setup failed:', mode, error?.code || error);
    }
  }
  return null;
}

// getRedirectResult() はページロード後の最初の呼び出しのみ結果を返す。
// 複数箇所から呼ぶと2回目以降は必ず null になるため、Promise をキャッシュして共有する。
let _redirectResultPromise = null;

function getRedirectResultOnce(auth) {
  if (!_redirectResultPromise) {
    _redirectResultPromise = auth.getRedirectResult();
  }
  return _redirectResultPromise;
}

async function tryRecoverGoogleRedirectSignIn() {
  try {
    const auth = firebase.auth();
    if (auth.currentUser) return auth.currentUser;
    await ensureAuthPersistence();
    // 共有Promiseから取得（二重呼び出しを防ぐ）
    const firstResult = await getRedirectResultOnce(auth);
    if (firstResult?.user) {
      if (!auth.currentUser) {
        try {
          await auth.updateCurrentUser(firstResult.user);
        } catch (restoreErr) {
          console.warn('Redirect ユーザーの復元(updateCurrentUser)に失敗:', restoreErr?.code || restoreErr);
        }
      }
      if (auth.currentUser) return auth.currentUser;
      if (firstResult.credential) {
        try {
          const credResult = await auth.signInWithCredential(firstResult.credential);
          if (credResult?.user) return credResult.user;
        } catch (credErr) {
          console.warn('Redirect 認証情報の再サインインに失敗:', credErr?.code || credErr);
        }
      }
      return firstResult.user;
    }
    if (auth.currentUser) return auth.currentUser;
    // onAuthStateChanged が遅れて発火するケースへの猶予
    await new Promise(resolve => setTimeout(resolve, 800));
    return auth.currentUser || null;
  } catch (error) {
    console.warn('Redirect recovery failed:', error?.code || error);
    return null;
  }
}

async function tryRecoverGoogleRedirectWithGrace(auth, waitMs = 1200) {
  const recovered = await tryRecoverGoogleRedirectSignIn();
  if (recovered) return recovered;

  await new Promise(resolve => setTimeout(resolve, waitMs));
  if (auth.currentUser) return auth.currentUser;

  return tryRecoverGoogleRedirectSignIn();
}

async function resolveRedirectSignInResult() {
  const pending = hasRecentGoogleRedirectPending();
  try {
    const auth = firebase.auth();
    await ensureAuthPersistence();
    // 共有Promiseから取得（tryRecoverGoogleRedirectSignIn との二重呼び出しを防ぐ）
    const result = await getRedirectResultOnce(auth);
    if (result && result.user) {
      console.log('✓ Redirect ログイン成功:', result.user.email || result.user.uid);
      if (!auth.currentUser) {
        try {
          await auth.updateCurrentUser(result.user);
        } catch (restoreErr) {
          console.warn('Redirect ユーザーの復元に失敗:', restoreErr?.code || restoreErr);
        }
      }
      setGoogleRedirectPending(false);
      hideError('login-error');
    }
  } catch (error) {
    console.warn('Redirect ログイン結果の取得に失敗:', error?.code || error);
    if (String(error?.code || '').startsWith('auth/')) {
      showError('login-error', getGoogleAuthErrorMessage(error));
    }
  } finally {
    if (!hasRecentGoogleRedirectPending()) {
      setGoogleRedirectPending(false);
    }
  }
}

function setGoogleLoginVisibility(visible) {
  const googleBtn = document.getElementById('google-login-btn');
  const divider = document.querySelector('#login-form-area .divider');
  if (googleBtn) googleBtn.classList.toggle('hidden', !visible);
  if (divider) divider.classList.toggle('hidden', !visible);
}

function renderGooglePopupFallbackButton() {
  const googleBtn = document.getElementById('google-login-btn');
  if (!googleBtn) return;

  googleBtn.innerHTML = '';
  const btn = document.createElement('button');
  btn.type = 'button';
  btn.id = 'btn-google-fallback-login';
  btn.className = 'btn btn-ghost login-submit';
  btn.textContent = 'Googleでログイン';
  btn.addEventListener('click', handleGoogleSignIn);
  googleBtn.appendChild(btn);
}

function getGoogleAuthErrorMessage(error) {
  const code = String(error?.code || '');
  const ua = String(navigator.userAgent || '');
  const isSafari = /Safari/i.test(ua) && !/Chrome|CriOS|Edg|EdgiOS|FxiOS|Firefox/i.test(ua);
  if (code === 'auth/operation-not-supported-in-this-environment') {
    return '現在の実行環境ではGoogleログインが使えません。http(s) で起動し、ブラウザのストレージ/Cookieを有効化してください（file:// では不可）。';
  }
  if (code === 'auth/popup-blocked') {
    return 'ポップアップがブロックされました。リダイレクト方式で再試行します。';
  }
  if (code === 'auth/popup-closed-by-user') {
    return 'Googleログインがキャンセルされました。';
  }
  if (code === 'auth/operation-not-allowed') {
    return 'Firebase ConsoleでGoogle認証が有効化されていません。';
  }
  if (code === 'auth/unauthorized-domain') {
    return 'このドメインは認証許可されていません。Firebaseの承認済みドメインに追加してください。';
  }
  if (code === 'auth/invalid-credential') {
    return 'Google認証情報が無効です。設定を確認してください。';
  }
  if (code === 'auth/network-request-failed') {
    return 'ネットワークエラーが発生しました。接続を確認して再試行してください。';
  }
  if (code === 'auth/web-storage-unsupported') {
    return 'ブラウザのストレージが無効なためログインできません。SafariのプライベートブラウズをOFFにして再試行してください。';
  }
  if (isSafari) {
    return 'SafariでGoogleログインに失敗しました。プライベートブラウズをOFFにし、Safari設定の「サイト越えトラッキングを防ぐ」を一時的にOFFにして再試行してください。';
  }
  return 'Googleログインに失敗しました。時間をおいて再試行してください。';
}

function shouldUseRedirectForGoogleSignIn() {
  try {
    const ua = String(navigator.userAgent || '');
    const isSafari = /Safari/i.test(ua) && !/Chrome|CriOS|Edg|EdgiOS|FxiOS|Firefox/i.test(ua);
    // Safari は popup が失敗しやすいため redirect を優先する。
    return isSafari;
  } catch {
    return false;
  }
}

// ===== ログイン処理 =====
async function handleEmailLogin() {
  const email = document.getElementById('login-email').value.trim();
  const password = document.getElementById('login-password').value;

  if (!email || !password) {
    showError('login-error', 'メールアドレスとパスワードを入力してください');
    return;
  }

  try {
    hideError('login-error');
    document.getElementById('btn-login').disabled = true;
    await ensureAuthPersistence();

    const auth = firebase.auth();
    const result = await auth.signInWithEmailAndPassword(email, password);
    console.log('✓ ログイン成功:', result.user.email);
  } catch (error) {
    console.error('✗ ログイン失敗:', error.code);
    let msg = 'ログインに失敗しました';
    if (error.code === 'auth/user-not-found') msg = 'ユーザーが見つかりません';
    if (error.code === 'auth/wrong-password') msg = 'パスワードが正しくありません';
    if (error.code === 'auth/invalid-credential') msg = 'メールアドレスまたはパスワードが正しくありません';
    if (error.code === 'auth/invalid-email') msg = 'メールアドレスが無効です';
    if (error.code === 'auth/too-many-requests') msg = '試行回数が多すぎます。10〜30分ほど待ってから再試行してください。急ぐ場合はパスワード再設定をご利用ください。';
    if (error.code === 'auth/network-request-failed') msg = 'ネットワークエラーです。接続を確認して再試行してください';

    // Google アカウントのみで作成されたメールを、メール/パスワードでログインしようとした場合の案内
    if (email && (error.code === 'auth/invalid-credential' || error.code === 'auth/user-not-found')) {
      try {
        const auth = firebase.auth();
        const methods = await auth.fetchSignInMethodsForEmail(email);
        if (Array.isArray(methods) && methods.includes('google.com') && !methods.includes('password')) {
          msg = 'このメールはGoogleログイン専用で登録されています。Googleでログインするか、パスワード再設定メールでパスワードを作成してください。';
        }
      } catch (methodErr) {
        console.warn('サインイン方式の確認に失敗:', methodErr?.code || methodErr);
      }
    }

    showError('login-error', msg);
  } finally {
    document.getElementById('btn-login').disabled = false;
  }
}

// ===== 新規登録処理 =====
async function handleRegister() {
  const email = document.getElementById('reg-email').value.trim();
  const password = document.getElementById('reg-password').value;
  const password2 = document.getElementById('reg-password2').value;

  if (!email || !password || !password2) {
    showError('reg-error', 'すべてのフィールドを入力してください');
    return;
  }

  if (password !== password2) {
    showError('reg-error', 'パスワードが一致しません');
    return;
  }

  if (password.length < 6) {
    showError('reg-error', 'パスワードは6文字以上である必要があります');
    return;
  }

  try {
    hideError('reg-error');
    document.getElementById('btn-register').disabled = true;
    
    const auth = firebase.auth();
    const db = firebase.firestore();
    
    const result = await auth.createUserWithEmailAndPassword(email, password);
    console.log('✓ ユーザー作成成功:', result.user.email);
    
    // Firestore に初期ユーザーデータを作成
    await db.collection('users').doc(result.user.uid).set({
      email: email,
      createdAt: new Date(),
      displayName: email.split('@')[0]
    });
    
    console.log('✓ Firestore にユーザードキュメント作成');
  } catch (error) {
    console.error('✗ ユーザー作成失敗:', error.code);
    let msg = 'ユーザー作成に失敗しました';
    if (error.code === 'auth/email-already-in-use') msg = 'このメールアドレスは既に使用されています';
    if (error.code === 'auth/invalid-email') msg = 'メールアドレスが無効です';
    if (error.code === 'auth/weak-password') msg = 'パスワードが弱すぎます';
    showError('reg-error', msg);
  } finally {
    document.getElementById('btn-register').disabled = false;
  }
}

// ===== パスワードリセット処理 =====
async function handlePasswordReset() {
  const email = document.getElementById('reset-email').value.trim();

  if (!email) {
    showError('reset-error', 'メールアドレスを入力してください');
    return;
  }

  try {
    hideError('reset-error');
    document.getElementById('btn-do-reset').disabled = true;
    
    const auth = firebase.auth();
    await auth.sendPasswordResetEmail(email);
    console.log('✓ パスワードリセットメール送信');
    document.getElementById('reset-success').classList.remove('hidden');
    
    // 3秒後にログインフォームに戻す
    setTimeout(() => {
      switchAuthForm('login');
    }, 3000);
  } catch (error) {
    console.error('✗ パスワードリセット失敗:', error.code);
    let msg = 'パスワードリセットに失敗しました';
    if (error.code === 'auth/user-not-found') msg = 'このメールアドレスのユーザーが見つかりません';
    if (error.code === 'auth/invalid-email') msg = 'メールアドレスが無効です';
    showError('reset-error', msg);
  } finally {
    document.getElementById('btn-do-reset').disabled = false;
  }
}

// ===== Google ログイン処理 =====
async function handleGoogleSignIn() {
  try {
    const auth = firebase.auth();
    await ensureAuthPersistence();
    auth.useDeviceLanguage();
    const provider = new firebase.auth.GoogleAuthProvider();
    provider.setCustomParameters({ prompt: 'select_account' });

    if (shouldUseRedirectForGoogleSignIn()) {
      showError('login-error', 'Safariのため、Googleログイン画面へ移動します...');
      setGoogleRedirectPending(true);
      await auth.signInWithRedirect(provider);
      return;
    }

    const result = await auth.signInWithPopup(provider);
    console.log('✓ Google ログイン成功:', result.user.email);
    setGoogleRedirectPending(false);
    
    // 新規ユーザーの場合、Firestore に情報を保存
    const db = firebase.firestore();
    const userRef = db.collection('users').doc(result.user.uid);
    const userDoc = await userRef.get();
    
    if (!userDoc.exists) {
      await userRef.set({
        email: result.user.email,
        displayName: result.user.displayName,
        photoURL: result.user.photoURL,
        createdAt: new Date()
      });
    }
  } catch (error) {
    console.error('✗ Google ログイン失敗:', error.code);
    if (error.code === 'auth/popup-blocked') {
      try {
        const auth = firebase.auth();
        const provider = new firebase.auth.GoogleAuthProvider();
        provider.setCustomParameters({ prompt: 'select_account' });
        showError('login-error', getGoogleAuthErrorMessage(error));
        setGoogleRedirectPending(true);
        await auth.signInWithRedirect(provider);
        return;
      } catch (redirectErr) {
        setGoogleRedirectPending(false);
        console.error('✗ Google リダイレクト失敗:', redirectErr?.code || redirectErr);
        showError('login-error', getGoogleAuthErrorMessage(redirectErr));
        return;
      }
    }
    setGoogleRedirectPending(false);
    showError('login-error', getGoogleAuthErrorMessage(error));
  }
}

// ===== ログアウト処理 =====
async function handleLogout() {
  try {
    const auth = firebase.auth();
    if (!auth.currentUser) {
      switchAuthForm('login');
      const overlay = document.getElementById('login-overlay');
      if (overlay) overlay.classList.remove('hidden');
      return;
    }

    // 通常ユーザーはログアウト後も「前回の続きから」を使えるように残す。
    if (typeof endSession === 'function') {
      endSession();
    }

    await auth.signOut();
    console.log('✓ ログアウト');
  } catch (error) {
    console.error('✗ ログアウト失敗:', error);
  }
}

// ===== 認証フォーム切り替え =====
function switchAuthForm(form) {
  document.getElementById('login-form-area').classList.toggle('hidden', form !== 'login');
  document.getElementById('register-form-area').classList.toggle('hidden', form !== 'register');
  document.getElementById('reset-form-area').classList.toggle('hidden', form !== 'reset');
  
  // エラーメッセージをクリア
  hideError('login-error');
  hideError('reg-error');
  hideError('reset-error');
  document.getElementById('reset-success').classList.add('hidden');
}

function closeLoginOverlayToHome() {
  const overlay = document.getElementById('login-overlay');
  if (overlay) overlay.classList.add('hidden');
  switchAuthForm('login');
  if (typeof showPage === 'function') showPage('study');
}

function updateStatsNavAvailability(isLoggedIn) {
  const statsBtn = document.getElementById('nav-stats-btn');
  if (!statsBtn) return;
  statsBtn.disabled = false;
  statsBtn.setAttribute('aria-disabled', 'false');
  if (isLoggedIn) {
    statsBtn.removeAttribute('title');
  } else {
    statsBtn.title = '成績・学習日カレンダーはログインまたは新規登録で利用できます';
  }
}

function updateManageNavAvailability(canManage) {
  const manageBtn = document.getElementById('nav-manage-btn');
  if (!manageBtn) return;
  manageBtn.classList.toggle('hidden', !canManage);
  manageBtn.setAttribute('aria-hidden', String(!canManage));
  if (canManage) {
    manageBtn.removeAttribute('title');
  } else {
    manageBtn.title = '問題管理ページは管理者ログイン後に利用できます';
  }
}

function updateAdminNavAvailability(canManage) {
  const adminBtn = document.getElementById('nav-admin-btn');
  if (!adminBtn) return;
  adminBtn.classList.toggle('hidden', !canManage);
  adminBtn.setAttribute('aria-hidden', String(!canManage));
  if (canManage) {
    adminBtn.removeAttribute('title');
  } else {
    adminBtn.title = '管理者ページは管理者ログイン後に利用できます';
  }
}

function openAdminLoginOverlay() {
  const overlay = document.getElementById('admin-login-overlay');
  if (!overlay) return;

  const auth = firebase.auth();
  const current = auth.currentUser;
  if (current && typeof isAdminUser === 'function') {
    const canManage = isAdminUser({ uid: current.uid, email: current.email, displayName: current.displayName || '' });
    if (canManage) {
      if (typeof showPage === 'function') showPage('admin');
      return;
    }
  }

  const usernameEl = document.getElementById('admin-login-username');
  const passwordEl = document.getElementById('admin-login-password');
  hideError('admin-login-error');
  if (usernameEl) usernameEl.value = '';
  if (passwordEl) passwordEl.value = '';

  overlay.classList.remove('hidden');
  if (usernameEl) usernameEl.focus();
}

function closeAdminLoginOverlay() {
  const overlay = document.getElementById('admin-login-overlay');
  if (!overlay) return;
  overlay.classList.add('hidden');
  hideError('admin-login-error');
}

function resolveAdminLoginEmail(inputId) {
  const raw = String(inputId || '').trim();
  return raw;
}

async function handleAdminLogin() {
  const username = document.getElementById('admin-login-username')?.value.trim() || '';
  const password = document.getElementById('admin-login-password')?.value || '';
  const btn = document.getElementById('btn-admin-login');

  if (!username || !password) {
    showError('admin-login-error', 'ユーザー名とパスワードを入力してください');
    return;
  }

  try {
    hideError('admin-login-error');
    if (btn) btn.disabled = true;

    const loginEmail = resolveAdminLoginEmail(username);
    if (!loginEmail || !loginEmail.includes('@')) {
      showError('admin-login-error', '管理者メールアドレスを入力してください');
      return;
    }

    const auth = firebase.auth();
    const result = await auth.signInWithEmailAndPassword(loginEmail, password);
    const canManage = typeof isAdminUser === 'function'
      ? isAdminUser({ uid: result.user.uid, email: result.user.email, displayName: result.user.displayName || '' })
      : false;

    if (!canManage) {
      await auth.signOut();
      showError('admin-login-error', 'このアカウントには管理者権限がありません');
      return;
    }

    closeAdminLoginOverlay();
    updateAdminNavAvailability(true);
    if (typeof showPage === 'function') showPage('admin');
  } catch (error) {
    console.error('✗ 管理者ログイン失敗:', error.code);
    let msg = '管理者ログインに失敗しました';
    if (error.code === 'auth/user-not-found') msg = 'ユーザーが見つかりません';
    if (error.code === 'auth/wrong-password') msg = 'パスワードが正しくありません';
    if (error.code === 'auth/invalid-email') msg = 'メールアドレスが無効です';
    if (error.code === 'auth/too-many-requests') msg = '試行回数が多すぎます。10〜30分ほど待ってから再試行してください。急ぐ場合はパスワード再設定をご利用ください。';
    showError('admin-login-error', msg);
  } finally {
    if (btn) btn.disabled = false;
  }
}

window.openAdminLoginOverlay = openAdminLoginOverlay;
window.closeAdminLoginOverlay = closeAdminLoginOverlay;
window.updateAdminNavAvailability = updateAdminNavAvailability;

// ===== 認証状態の監視 =====
function setupAuthStateListener() {
  const auth = firebase.auth();
  
  auth.onAuthStateChanged(async (user) => {
    const appEl = document.getElementById('app');
    const overlayEl = document.getElementById('login-overlay');
    const userNameEl = document.getElementById('current-user-name');
    const btnLogout = document.getElementById('btn-logout');

    if (user) {
      console.log('✓ ユーザーはログイン中:', user.email);
      setGoogleRedirectPending(false);

      // ログインオーバーレイを隠す
      if (overlayEl) overlayEl.classList.add('hidden');
      if (appEl) appEl.classList.remove('hidden');
      
      // グローバル変数にユーザー情報を保存
      window.currentUser = {
        uid: user.uid,
        email: user.email,
        displayName: user.displayName || user.email.split('@')[0]
      };
      
      // 問題データを読み込む
      if (typeof loadData === 'function') loadData();
      if (typeof refreshFilterOptions === 'function') refreshFilterOptions();
      updateStatsNavAvailability(true);
      const canManage = typeof isAdminUser === 'function' ? isAdminUser(window.currentUser) : false;
      updateAdminNavAvailability(canManage);
      updateManageNavAvailability(canManage);

      if (typeof pullQuestionsFromCloudIfNeeded === 'function') {
        await pullQuestionsFromCloudIfNeeded(true);
      }

      if (!canManage) {
        if (typeof pullRecordsFromCloudIfNeeded === 'function') {
          await pullRecordsFromCloudIfNeeded(true);
        }

        const savedSnapshot = typeof readSavedStudySession === 'function'
          ? readSavedStudySession(window.currentUser.uid)
          : null;
        if (savedSnapshot) {
          console.log('✓ 前回の学習セッションを検出:', savedSnapshot.queueIds?.length || 0, '件');
        } else {
          console.log('ℹ 前回の学習セッションは見つかりませんでした');
        }

        if (typeof updateResumeSessionButton === 'function') updateResumeSessionButton();
        if (typeof showPage === 'function') showPage('study');
      }

      if (canManage) closeAdminLoginOverlay();

      if (userNameEl) userNameEl.textContent = window.currentUser.displayName;
      if (btnLogout) btnLogout.textContent = 'ログアウト';
    } else {
      console.log('✗ ユーザーはログインしていません');
      const pendingGoogleRedirect = hasRecentGoogleRedirectPending();

      if (pendingGoogleRedirect) {
        const recovered = await tryRecoverGoogleRedirectWithGrace(auth);
        if (recovered) {
          // onAuthStateChanged が再発火してログイン分岐に入るため、ここでは終了
          return;
        }
      }

      if (typeof stopCloudRealtimeSubscriptions === 'function') {
        stopCloudRealtimeSubscriptions();
      }
      if (overlayEl) overlayEl.classList.add('hidden');
      if (appEl) appEl.classList.remove('hidden');

      // グローバル変数をクリア
      window.currentUser = null;

      // ローカル保存データを再読込して、管理者編集を含む最新状態を反映する。
      if (typeof loadData === 'function') loadData();

      // ゲストでも問題データは利用可能にする
      if (typeof syncBundledQuestions === 'function') await syncBundledQuestions();
      if (typeof refreshFilterOptions === 'function') refreshFilterOptions();
      updateStatsNavAvailability(false);
      const canManage = false;
      updateAdminNavAvailability(canManage);
      updateManageNavAvailability(canManage);

      if (userNameEl) userNameEl.textContent = canManage ? '管理者' : 'ゲスト';
      if (btnLogout) btnLogout.textContent = 'ログイン';

      if (pendingGoogleRedirect) {
        setGoogleRedirectPending(false);
        if (overlayEl) overlayEl.classList.remove('hidden');
        showError('login-error', 'Google認証後のセッション復元に失敗しました。Safari/Chromeで直接開き、プライベートブラウズをOFFにして再試行してください。');
      }

      if (canManage && typeof showPage === 'function') showPage('admin');
      if (!canManage && typeof showPage === 'function') showPage('study');
    }
  });
}

// ===== イベントリスナー登録 =====
document.addEventListener('DOMContentLoaded', () => {
  const hasGoogleClientId = !!getGoogleClientId();
  setGoogleLoginVisibility(true);

  // リダイレクト方式で戻ってきた認証結果を先に回収しておく。
  resolveRedirectSignInResult();

  // Firebase 初期化を待つ
  if (!window.firebaseInitialized) {
    console.warn('⚠ Firebase が初期化されていません');
    // 短い遅延後に再試行
    setTimeout(() => setupAuthStateListener(), 1000);
  } else {
    setupAuthStateListener();
  }

  // ログインボタン
  const btnLogin = document.getElementById('btn-login');
  if (btnLogin) {
    btnLogin.addEventListener('click', handleEmailLogin);
  }

  // 登録ボタン
  const btnRegister = document.getElementById('btn-register');
  if (btnRegister) {
    btnRegister.addEventListener('click', handleRegister);
  }

  // パスワードリセットボタン
  const btnReset = document.getElementById('btn-do-reset');
  if (btnReset) {
    btnReset.addEventListener('click', handlePasswordReset);
  }

  // フォーム切り替えボタン
  const btnShowRegister = document.getElementById('btn-show-register');
  if (btnShowRegister) {
    btnShowRegister.addEventListener('click', () => switchAuthForm('register'));
  }

  const btnShowReset = document.getElementById('btn-show-reset');
  if (btnShowReset) {
    btnShowReset.addEventListener('click', () => switchAuthForm('reset'));
  }

  const btnShowLoginFromRegister = document.getElementById('btn-show-login');
  if (btnShowLoginFromRegister) {
    btnShowLoginFromRegister.addEventListener('click', () => switchAuthForm('login'));
  }

  const btnShowLoginFromReset = document.getElementById('btn-show-login-from-reset');
  if (btnShowLoginFromReset) {
    btnShowLoginFromReset.addEventListener('click', () => switchAuthForm('login'));
  }

  const btnCloseLoginOverlay = document.getElementById('btn-close-login-overlay');
  if (btnCloseLoginOverlay) {
    btnCloseLoginOverlay.addEventListener('click', closeLoginOverlayToHome);
  }

  // 管理者ログインモーダル
  const btnAdminLogin = document.getElementById('btn-admin-login');
  if (btnAdminLogin) {
    btnAdminLogin.addEventListener('click', handleAdminLogin);
  }

  const btnAdminLoginCancel = document.getElementById('btn-admin-login-cancel');
  if (btnAdminLoginCancel) {
    btnAdminLoginCancel.addEventListener('click', closeAdminLoginOverlay);
  }

  const adminOverlay = document.getElementById('admin-login-overlay');
  if (adminOverlay) {
    adminOverlay.addEventListener('click', (e) => {
      if (e.target === adminOverlay) closeAdminLoginOverlay();
    });
  }

  // ログアウトボタン
  const btnLogout = document.getElementById('btn-logout');
  if (btnLogout) {
    btnLogout.addEventListener('click', handleLogout);
  }

  const btnAdminLogout = document.getElementById('btn-admin-logout');
  if (btnAdminLogout) {
    btnAdminLogout.addEventListener('click', handleLogout);
  }

  const btnOpenManageFromAdmin = document.getElementById('btn-open-manage-from-admin');
  if (btnOpenManageFromAdmin) {
    btnOpenManageFromAdmin.addEventListener('click', () => {
      if (typeof showPage === 'function') showPage('manage');
    });
  }

  // Google ログインは Client ID 設定済みなら GIS ボタン、未設定なら Firebase Popup ボタンを表示
  if (hasGoogleClientId) {
    if (window.google && window.google.accounts && window.google.accounts.id) {
      initGoogleSignIn();
    } else {
      // Google Sign-In ライブラリが遅延読み込みされた場合
      const checkGoogle = setInterval(() => {
        if (window.google && window.google.accounts && window.google.accounts.id && !window.googleSignInInitialized) {
          initGoogleSignIn();
          clearInterval(checkGoogle);
        }
      }, 100);
    }
  } else {
    renderGooglePopupFallbackButton();
  }
});

// Google Sign-In の初期化
function initGoogleSignIn() {
  if (window.googleSignInInitialized) return;
  const GOOGLE_CLIENT_ID = getGoogleClientId();

  if (!GOOGLE_CLIENT_ID || GOOGLE_CLIENT_ID.includes('YOUR_')) {
    renderGooglePopupFallbackButton();
    setGoogleLoginVisibility(true);
    return;
  }

  window.googleSignInInitialized = true;
  setGoogleLoginVisibility(true);

  try {
    google.accounts.id.initialize({
      client_id: GOOGLE_CLIENT_ID,
      callback: handleGoogleSignInCallback
    });

    const googleBtn = document.getElementById('google-login-btn');
    if (googleBtn) {
      googleBtn.innerHTML = '';
      google.accounts.id.renderButton(googleBtn, { theme: 'outline', size: 'large' });
    }
  } catch (error) {
    console.warn('Google Sign-In initialization skipped:', error);
    renderGooglePopupFallbackButton();
    setGoogleLoginVisibility(true);
  }
}

// Google ログインコールバック
async function handleGoogleSignInCallback(response) {
  try {
    const auth = firebase.auth();
    // Google の ID トークンをFirebase に渡す
    const credential = firebase.auth.GoogleAuthProvider.credential(response.credential);
    await auth.signInWithCredential(credential);
    console.log('✓ Google ログイン成功');
  } catch (error) {
    console.error('✗ Google ログイン失敗:', error);
    showError('login-error', getGoogleAuthErrorMessage(error));
  }
}

// メールアドレス入力時にEnter キーでログイン
document.addEventListener('keydown', (e) => {
  if (e.key === 'Enter') {
    const adminOverlay = document.getElementById('admin-login-overlay');
    if (adminOverlay && !adminOverlay.classList.contains('hidden')) {
      handleAdminLogin();
      return;
    }

    if (!document.getElementById('login-form-area').classList.contains('hidden')) {
      handleEmailLogin();
    } else if (!document.getElementById('register-form-area').classList.contains('hidden')) {
      handleRegister();
    } else if (!document.getElementById('reset-form-area').classList.contains('hidden')) {
      handlePasswordReset();
    }
  }
});

console.log('✓ Auth module loaded');
