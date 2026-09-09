import nodemailer from 'nodemailer';

function requiredText(value, name) {
  const text = String(value ?? '').trim();
  if (!text) throw new Error(`${name} is required`);
  return text;
}

function parsePort(value) {
  const port = Number(value ?? 587);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error('COMMUNITY_SMTP_PORT must be an integer between 1 and 65535');
  }
  return port;
}

function parseBoolean(value, defaultValue = false) {
  if (value == null || value === '') return defaultValue;
  if (value === true || value === 'true') return true;
  if (value === false || value === 'false') return false;
  throw new Error('SMTP boolean configuration must be true or false');
}

export function smtpConfigurationFromEnvironment(environment = process.env) {
  return {
    host: environment.COMMUNITY_SMTP_HOST,
    port: environment.COMMUNITY_SMTP_PORT,
    secure: environment.COMMUNITY_SMTP_SECURE,
    user: environment.COMMUNITY_SMTP_USER,
    password: environment.COMMUNITY_SMTP_PASSWORD,
    from: environment.COMMUNITY_SMTP_FROM,
    replyTo: environment.COMMUNITY_SMTP_REPLY_TO,
  };
}

export function validateSmtpConfiguration(configuration) {
  const host = requiredText(configuration?.host, 'COMMUNITY_SMTP_HOST');
  const port = parsePort(configuration?.port);
  const secure = parseBoolean(configuration?.secure, port === 465);
  const user = requiredText(configuration?.user, 'COMMUNITY_SMTP_USER');
  const password = requiredText(
    configuration?.password,
    'COMMUNITY_SMTP_PASSWORD',
  );
  const from = requiredText(configuration?.from, 'COMMUNITY_SMTP_FROM');
  const replyTo = String(configuration?.replyTo ?? '').trim() || undefined;
  return { host, port, secure, user, password, from, replyTo };
}

function verificationMessage({ code, expiresMinutes }) {
  return {
    subject: 'sohun 邮箱验证码',
    text: [
      '你正在验证 sohun 账号邮箱。',
      '',
      `验证码：${code}`,
      `有效期：${expiresMinutes} 分钟`,
      '',
      '如果不是你本人操作，请忽略此邮件。不要把验证码告诉任何人。',
    ].join('\n'),
  };
}

function passwordResetMessage({ code, expiresMinutes }) {
  return {
    subject: 'sohun 密码重置验证码',
    text: [
      '你正在重置 sohun 账号密码。',
      '',
      `验证码：${code}`,
      `有效期：${expiresMinutes} 分钟`,
      '',
      '如果不是你本人操作，请忽略此邮件。不要把验证码告诉任何人。',
    ].join('\n'),
  };
}

export function createSmtpEmailSender(configuration) {
  const resolved = validateSmtpConfiguration(configuration);
  const transporter = nodemailer.createTransport({
    pool: true,
    host: resolved.host,
    port: resolved.port,
    secure: resolved.secure,
    requireTLS: !resolved.secure,
    auth: {
      user: resolved.user,
      pass: resolved.password,
    },
    disableFileAccess: true,
    disableUrlAccess: true,
    tls: { rejectUnauthorized: true },
  });

  async function send(to, message) {
    const result = await transporter.sendMail({
      from: resolved.from,
      to,
      ...(resolved.replyTo ? { replyTo: resolved.replyTo } : {}),
      subject: message.subject,
      text: message.text,
    });
    return { messageId: result.messageId ?? null };
  }

  return {
    async verify() {
      await transporter.verify();
      return true;
    },
    async sendVerification(input) {
      return send(input.to, verificationMessage(input));
    },
    async sendPasswordReset(input) {
      return send(input.to, passwordResetMessage(input));
    },
    close() {
      transporter.close();
    },
  };
}
