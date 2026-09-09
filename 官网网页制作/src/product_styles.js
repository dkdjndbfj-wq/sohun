import { glassButtonStyles } from './site_theme.js';

export const productStyles = `
  .home-main{overflow:clip}
  .content-width{width:min(1120px,calc(100% - 64px));margin:0 auto}
  .hero{position:relative;padding:64px 0 0;text-align:center}
  .hero h1{color:var(--ink);font-size:clamp(44px,4.3vw,62px);line-height:1.2;letter-spacing:-2.6px;font-weight:650}
  .hero h1 span{display:block;color:var(--heading-green)}
  .hero-description{max-width:600px;margin:20px auto 0;color:var(--muted);font-size:16px;line-height:1.8;text-wrap:pretty}
  .hero-actions{display:flex;justify-content:center;flex-wrap:wrap;gap:12px;margin-top:24px}
  .hero-actions .primary-link,.hero-actions .secondary-link{min-height:50px}
  .platform-note{font-size:11px;color:var(--faint);margin-top:15px}
  .desktop-showcase{width:min(1180px,calc(100% - 64px));margin:40px auto 0}
  .preview-tabs{display:inline-flex;align-items:center;gap:5px;padding:5px;margin-bottom:18px;background:var(--surface);border:1px solid var(--rim);border-radius:12px}
  .preview-tab{display:inline-flex;justify-content:center;align-items:center;gap:8px;min-height:38px;padding:0 19px;border-radius:9px;font-size:12px}
  .preview-tab .icon{width:17px;height:17px}
  .preview-tab[aria-selected="true"]{font-weight:600}
  .desktop-image-link{display:block;padding:8px;border:1px solid var(--rim);border-radius:18px;background:var(--surface);box-shadow:0 24px 55px -35px rgba(18,22,20,.25)}
  .desktop-image-link img{display:block;width:100%;height:auto;border-radius:10px}
  .desktop-screen figcaption{display:flex;align-items:center;justify-content:space-between;gap:16px;text-align:left;padding:17px 9px 0;color:var(--muted);font-size:12px}
  .desktop-screen figcaption small{color:var(--faint);font-size:10px;margin-left:14px}
  .desktop-screen figcaption a{display:inline-flex;align-items:center;gap:7px;flex:none;min-height:32px;padding:4px 10px;border-radius:9px;font-size:12px}
  ${glassButtonStyles('.preview-tab,.desktop-screen figcaption a', { primarySelector: '.preview-tab[aria-selected="true"]' })}
  .preview-note{display:flex;justify-content:center;gap:20px;align-items:center;margin:28px 0 0;font-size:11px;color:var(--faint)}
  .preview-note span{display:inline-flex;gap:6px;align-items:center}.preview-note .icon{width:14px;height:14px}
  .capabilities{padding:96px 0 84px}
  .section-heading-row{display:flex;justify-content:space-between;align-items:flex-end;gap:40px}
  .section-heading-row h2,.section-copy h2{color:var(--ink);font-size:clamp(31px,3vw,43px);line-height:1.4;letter-spacing:-1.1px}
  .section-heading-row>p{max-width:380px;color:var(--muted);font-size:14px;line-height:1.9;padding-bottom:4px}
  .feature-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));margin-top:48px;padding-top:34px;border-top:1px solid var(--line)}
  .feature-item{padding:0 35px;border-right:1px solid var(--line)}
  .feature-item:first-child{padding-left:0}.feature-item:last-child{border:0;padding-right:0}
  .feature-icon{display:grid;place-items:center;width:43px;height:43px;border:1px solid var(--rim);border-radius:12px;background:var(--green-soft);color:var(--green-dark);margin-bottom:23px}
  .feature-icon .icon{width:23px;height:23px}.feature-item h3{font-size:18px;margin-bottom:10px}
  .feature-item p{font-size:13px;line-height:1.9;color:var(--muted)}
  .feature-meta{display:block;margin-top:20px;color:var(--green-dark);font-size:11px}
  .desktop-reference{margin-top:38px;text-align:center}.desktop-reference .text-link{font-size:12px}
  .workflow-band{background:rgba(255,255,255,.48);border-block:1px solid var(--rim);padding:76px 0}
  .workflow-layout{display:grid;grid-template-columns:1fr 1fr;align-items:center;gap:90px}
  .section-copy>p{color:var(--muted);font-size:14px;line-height:1.9;margin-top:20px}
  .workflow-steps{list-style:none;padding:0;margin:0;display:grid;gap:0}
  .workflow-steps li{display:flex;align-items:flex-start;gap:22px;padding:24px 0;border-bottom:1px solid var(--line)}
  .workflow-steps li:last-child{border-bottom:0}
  .step-number{font:500 15px/28px system-ui,sans-serif;color:var(--green-dark)}
  .workflow-steps strong{display:block;font-size:16px;font-weight:600}
  .workflow-steps p{font-size:13px;color:var(--muted);margin-top:6px}
  .connected-section{padding:88px 0}
  .connected-heading{text-align:center;margin-bottom:43px}
  .connected-heading h2{font-size:clamp(31px,3vw,43px);letter-spacing:-1px;color:var(--ink)}
  .connected-heading p{color:var(--muted);font-size:14px;margin-top:13px}
  .connected-grid{display:grid;grid-template-columns:1fr 1fr;gap:24px}
  .connected-card{padding:35px;background:var(--surface);border:1px solid var(--rim);border-radius:16px;box-shadow:var(--shadow)}
  .connected-card h3{font-size:24px;letter-spacing:-.5px}.connected-card>p{font-size:13px;line-height:1.9;color:var(--muted);margin-top:13px;max-width:400px}
  .connected-card .text-link{margin-top:23px;font-size:13px}
  .download-section{text-align:center;padding:76px 24px 82px;border-top:1px solid var(--line);background:radial-gradient(ellipse at 50% 90%,rgba(0,180,42,.06),transparent 70%)}
  .download-section h2{font-size:clamp(32px,3.4vw,46px);line-height:1.4;letter-spacing:-1.3px;color:var(--ink)}
  .download-section>p{color:var(--muted);font-size:14px;margin:18px 0 25px}
  .download-section .primary-link{min-height:52px;padding:0 26px}.download-section .platform-note{margin-top:16px}
  .download-symbol{display:grid;place-items:center;width:58px;height:58px;border-radius:16px;background:var(--surface);border:1px solid var(--rim);margin:0 auto 27px;box-shadow:var(--shadow);color:var(--green-dark)}
  .download-symbol .icon{width:26px;height:26px}
  .download-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:20px;width:min(800px,100%);margin:32px auto 0;text-align:left}
  .download-card{padding:28px;background:var(--surface);border:1px solid var(--rim);border-radius:16px;box-shadow:var(--shadow)}
  .download-card[data-current-platform]{border-color:rgba(0,180,42,.3)}
  .download-card-heading{display:flex;align-items:center;gap:15px}
  .download-platform-icon{display:grid;place-items:center;width:48px;height:48px;background:var(--green-soft);color:var(--green-dark);border-radius:13px;flex:none}
  .download-platform-icon .icon{width:25px;height:25px}
  .download-card h3{font:650 24px/1.3 system-ui,sans-serif;letter-spacing:-.5px}
  .download-card-heading span{display:block;margin-top:4px;color:var(--muted);font-size:12px}
  .download-card>p{margin:22px 0 12px;font-size:13px;color:var(--muted);line-height:1.8}
  .download-format{font-size:11px;color:var(--faint);margin-bottom:23px}
  .download-card .platform-download{width:100%;padding:0 14px;font-size:13px;min-height:48px}
  .download-pending{display:flex;align-items:center;justify-content:center;text-align:center;min-height:48px;padding:10px 12px;border:1px solid var(--line);border-radius:12px;background:rgba(255,255,255,.5);font-size:12px;color:var(--muted)}
  .download-section>.download-platform-note{max-width:760px;margin:22px auto 0;font-size:12px;line-height:1.8;color:var(--muted)}
  .intro-enter{animation:intro-enter .65s cubic-bezier(.22,.68,.3,1) both}.intro-delay{animation-delay:.1s}
  @keyframes intro-enter{from{opacity:0;transform:translateY(14px)}to{opacity:1;transform:translateY(0)}}
  @media(max-width:1000px){.workflow-layout{gap:45px}.connected-card{padding:28px}.section-heading-row>p{max-width:310px}}
  @media(max-width:800px){
    .content-width{width:calc(100% - 40px)}.hero{padding-top:55px}.hero h1{font-size:49px}
    .hero-description{max-width:500px;font-size:14px;padding:0 25px}
    .desktop-showcase{width:calc(100% - 40px);margin-top:32px}
    .capabilities{padding:72px 0}.section-heading-row{display:block}.section-heading-row>p{margin-top:18px;max-width:500px}
    .feature-item{padding:0 22px}.feature-item h3{font-size:16px}
    .workflow-layout{grid-template-columns:1fr;gap:22px}.workflow-band{padding:55px 0}.section-copy>p{max-width:500px}
    .connected-section{padding:68px 0}.connected-grid{gap:18px}.connected-card{padding:25px}.connected-card h3{font-size:21px}
  }
  @media(max-width:560px){
    .hero{padding-top:46px}.hero h1{font-size:39px;letter-spacing:-1.7px}
    .hero-description{margin-top:19px;padding:0 25px;font-size:13px;line-height:1.9}
    .hero-actions{gap:10px;margin:24px 20px 0}.hero-actions .primary-link,.hero-actions .secondary-link{font-size:12px;padding:0 15px;min-height:47px}.hero-actions .icon{width:17px;height:17px}
    .platform-note{font-size:10px;margin-top:13px}.desktop-showcase{width:calc(100% - 24px);margin-top:30px}
    .preview-tabs{margin-bottom:13px}.preview-tab{min-height:36px;padding:0 16px;font-size:11px}
    .desktop-image-link{padding:4px;border-radius:12px}.desktop-image-link img{border-radius:7px}
    .desktop-screen figcaption{padding:13px 7px 0;font-size:11px;gap:8px}.desktop-screen figcaption small{display:block;margin:3px 0 0;font-size:9px}.desktop-screen figcaption a{font-size:11px}
    .preview-note{gap:12px;margin-top:22px;font-size:10px}.preview-note .icon{width:12px;height:12px}
    .feature-grid{grid-template-columns:1fr;margin-top:30px;padding-top:0}
    .feature-item,.feature-item:first-child,.feature-item:last-child{position:relative;border:0;border-bottom:1px solid var(--line);padding:27px 0 26px 61px}
    .feature-item .feature-icon{position:absolute;top:28px;left:0;margin:0;width:40px;height:40px}
    .feature-item h3{font-size:17px}.feature-item p{font-size:12px}.feature-meta{margin-top:13px;font-size:10px}.desktop-reference{margin-top:26px}
    .section-heading-row h2,.section-copy h2{font-size:31px}.section-heading-row>p{font-size:13px}.capabilities{padding:60px 0 50px}
    .workflow-steps li{gap:16px;padding:20px 0}.workflow-steps strong{font-size:15px}.workflow-steps p{font-size:12px}
    .connected-heading{margin-bottom:30px;text-align:left}.connected-heading h2{font-size:30px}.connected-heading p{font-size:13px}
    .connected-grid{grid-template-columns:1fr}.connected-card{padding:27px 25px}.connected-card h3{font-size:23px}.connected-section{padding:60px 0}
    .download-section{padding:58px 20px 64px}.download-section h2{font-size:31px;letter-spacing:-1px}.download-section>p{font-size:13px;max-width:300px;margin:17px auto 24px}.download-symbol{margin-bottom:23px}
    .download-grid{grid-template-columns:1fr;gap:16px;margin-top:26px}.download-card{padding:24px}.download-section>.download-platform-note{max-width:100%;font-size:11px;margin-top:20px}
  }
`;
