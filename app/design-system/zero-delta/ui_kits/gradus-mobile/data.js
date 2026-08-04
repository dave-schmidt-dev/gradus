/* Mobile fixture: same snapshot fields, plus the countdown labels the phone shows. */
window.GRADUS_MOBILE = [
  { name:'Claude', badge:'live', warning:true, windows:[
    { label:'5h', name:'Session window', percent:7, reset:'22:00', countdown:'in 1h 29m', pace:'over -23pt' },
    { label:'1w', name:'Weekly window', percent:48, reset:'Mar 17 15:59', countdown:'in 3d 19h', pace:'over -6pt' }] },
  { name:'Cursor', offline:'3m', windows:[
    { label:'ac', name:'Auto + Composer', percent:31, reset:'Apr 01 00:00', countdown:'in 18d', pace:'over -11pt' },
    { label:'ap', name:'API pool', percent:88, reset:'Apr 01 00:00', countdown:'in 18d', pace:'under +19pt' }] },
  { name:'OpenCode Go', badge:'cached 12m', windows:[
    { label:'mo', name:'Monthly quota', percent:41, reset:'Apr 02 00:00', countdown:'in 19d', pace:'over -8pt' },
    { label:'5h', name:'Session window', percent:92, reset:'19:05', countdown:'in 4h 12m', pace:'under +21pt' },
    { label:'1w', name:'Weekly window', percent:88, reset:'Mar 20 08:00', countdown:'in 6d 23h', pace:'under +14pt' }] },
  { name:'Copilot', badge:'live', windows:[
    { label:'mo', name:'Premium requests', percent:63, reset:'Apr 01 00:00', countdown:'in 18d', pace:'on pace' }] },
  { name:'Codex', badge:'live', windows:[
    { label:'5h', name:'Session window', percent:74, reset:'13:16', countdown:'in 4h 46m', pace:'under +38pt' },
    { label:'1w', name:'Weekly window', percent:85, reset:'Mar 18 09:00', countdown:'in 4d 0h', pace:'on pace' }] },
  { name:'Antigravity', badge:'live', windows:[
    { label:'5h', name:'Gemini 5-hour', percent:100, reset:'18:30', countdown:'in 3h 30m', pace:'under +12pt' },
    { label:'1w', name:'Gemini weekly', percent:74, reset:'Mar 18 09:00', countdown:'in 4d 0h', pace:'on pace' },
    { label:'cg5', name:'Claude + GPT 5-hour', percent:62, reset:'18:30', countdown:'in 3h 30m', pace:'under +9pt' }] },
];
