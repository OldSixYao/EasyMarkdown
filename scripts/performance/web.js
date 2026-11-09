const records=[];
const prefs={fontSize:16,width:780,appearance:'system',remoteImages:false};
const render=(text,options,label)=>{
  const before=[...content.querySelectorAll('h2')];
  const start=performance.now();
  window.updateDocument(text,'markdown','file:///tmp/performance-review.md',options,{});
  const ms=performance.now()-start;
  const after=[...content.querySelectorAll('h2')];
  records.push({label,chars:text.length,totalMs:ms,headings:after.length,
    retainedHeadings:after.filter((node,i)=>node===before[i]).length,domNodes:content.querySelectorAll('*').length});
};
for(const count of [300,1500,3500]) {
  const source=Array.from({length:count},(_,i)=>`## Heading ${i}\n\nParagraph ${i} words for testing **bold** and [links](https://example.com) with \`inline\`.\n\n`).join('');
  render(source,prefs,'initial-'+count);
  for(let round=0;round<7;round++) render(source.replace('Paragraph '+Math.floor(count/2)+' ',
    'Paragraph '+Math.floor(count/2)+' edited-'+round+' '),prefs,'local-'+count);
  for(let round=0;round<7;round++) render(source.replace('Paragraph 0 ','Paragraph 0 start-'+round+' ')
    .replace('Paragraph '+(count-1)+' ','Paragraph '+(count-1)+' end-'+round+' '),prefs,'distant-'+count);
  render(source,prefs,'restore-'+count);
  for(let round=0;round<7;round++) render(source,{...prefs,fontSize:16+round},'preferences-'+count);
  let start=performance.now();
  const result=window.updateReaderSearch('words',false,0,0);
  records.push({label:'search-'+count,totalMs:performance.now()-start,matches:result.count,
    groups:readerSearchIndex.length,spans:readerSearchIndex.reduce((sum,g)=>sum+g.spans.length,0)});
  window.updateReaderSearch('',false,0,0);
}
return records;
