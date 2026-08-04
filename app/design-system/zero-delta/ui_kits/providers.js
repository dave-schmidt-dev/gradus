/* Shared fixture data for the Gradus UI kits — shapes match .state/snapshot-v2.json. */
window.GRADUS_FIXTURE = [
  { name:'Antigravity', badge:'live', windows:[
    { label:'5h', percent:100, reset:'18:30', pace:'under +12pt' },
    { label:'1w', percent:74, reset:'Mar 18 09:00', pace:'on pace' },
    { label:'cg5', percent:62, reset:'18:30', pace:'under +9pt' }] },
  { name:'Claude', badge:'live', warning:true, windows:[
    { label:'5h', percent:7, reset:'22:00', pace:'over -23pt' },
    { label:'1w', percent:48, reset:'Mar 17 15:59', pace:'over -6pt' }] },
  { name:'Codex', badge:'live', windows:[
    { label:'5h', percent:74, reset:'13:16', pace:'under +38pt' },
    { label:'1w', percent:85, reset:'Mar 18 09:00', pace:'on pace' }] },
  { name:'Copilot', badge:'live', windows:[
    { label:'mo', percent:63, reset:'Apr 01 00:00', pace:'on pace' }] },
  { name:'OpenCode Go', badge:'cached 12m', badgeTone:'cached', windows:[
    { label:'5h', percent:92, reset:'19:05', pace:'under +21pt' },
    { label:'1w', percent:88, reset:'Mar 20 08:00', pace:'under +14pt' },
    { label:'mo', percent:41, reset:'Apr 02 00:00', pace:'over -8pt' }] },
  { name:'Cursor', offline:'3m', windows:[
    { label:'ac', percent:31, reset:'Apr 01 00:00', pace:'over -11pt' },
    { label:'ap', percent:88, reset:'Apr 01 00:00', pace:'under +19pt' }] },
];
window.GRADUS_DEPLETED = [
  { name:'Vibe', windows:[{ label:'mo', percent:0, reset:'Apr 01 00:00', state:'depleted' }] },
];
