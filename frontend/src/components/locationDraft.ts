export type Mobile = {service_areas?:string[];dispatch_source?:string;dispatch_location_key?:string;travel_buffer_minutes?:number}
export type Location = {key:string;existing_shop_id?:number;name:string;address?:string;timezone?:string;operating_model?:string;mobile?:Mobile}
export type Defaults = {timezone?:string;operating_model?:string;mobile?:Mobile}
export type LocationErrors = Record<string,string>
export function locationErrors(locations:Location[],defaults:Defaults,zones:string[],complete:boolean):LocationErrors{
 const errors:LocationErrors={}
 for(const l of locations){
  const zone=l.timezone||defaults.timezone||'',model=l.operating_model||defaults.operating_model
  const mobile={...defaults.mobile,...l.mobile}
  const put=(field:string,message:string)=>{errors[`${l.key}-${field}`]=message}
  if(!l.name.trim())put('name','Give this location a name.')
  if(!zone || zones.length>0&&!zones.includes(zone))put('timezone','Choose a supported timezone from the suggestions.')
  if(!['in_shop','mobile','both'].includes(model||''))put('operating_model','Choose how customers receive services.')
  if(complete&&!l.address?.trim())put('address',model==='mobile'?'Enter the address your team will leave from.':'Enter the shop address.')
  if(model!=='in_shop'){
   if(complete&&!mobile.service_areas?.length)put('areas','Add at least one city or service area.')
   if(mobile.service_areas?.some(s=>!s.trim()||new TextEncoder().encode(s).length>200)|| (mobile.service_areas?.length||0)>20)put('areas','Use up to 20 areas, each no more than 200 bytes.')
   if(complete&&!['this_location','location_key'].includes(mobile.dispatch_source||''))put('dispatch','Choose where your mobile team starts.')
   if(mobile.dispatch_source==='location_key'&&!locations.some(x=>x.key===mobile.dispatch_location_key))put('dispatch','Choose an available starting location.')
   if((complete||mobile.travel_buffer_minutes!==undefined)&&(!Number.isInteger(mobile.travel_buffer_minutes)||mobile.travel_buffer_minutes!<0||mobile.travel_buffer_minutes!>240))put('buffer','Enter whole minutes from 0 to 240.')
  }
 }
 return errors
}

export function cleanLocationInputs<T extends {locations:Location[];defaults:Defaults}>(proposal:T):T {
 const clean=(mobile:Mobile):Mobile=>({...mobile,...(mobile.service_areas?{service_areas:mobile.service_areas.map(s=>s.trim()).filter(Boolean)}:{})})
 return {...proposal,defaults:{...proposal.defaults,...(proposal.defaults.mobile?{mobile:clean(proposal.defaults.mobile)}:{})},locations:proposal.locations.map(l=>({...l,...(l.mobile?{mobile:clean(l.mobile)}:{})}))}
}
