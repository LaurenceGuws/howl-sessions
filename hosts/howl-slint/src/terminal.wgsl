struct Globals { surface:vec4<u32> };
@group(0) @binding(0) var<uniform> globals:Globals;
@group(0) @binding(1) var atlas:texture_2d<u32>;
struct V { @builtin(position) pos:vec4<f32>,
 @location(0) @interpolate(flat) dst:vec4<i32>,
 @location(1) @interpolate(flat) src:vec4<u32>,
 @location(2) @interpolate(flat) color:vec4<u32>,
 @location(3) @interpolate(flat) kind:vec4<u32>,
 @location(4) @interpolate(flat) clip:vec4<i32> };
@vertex fn vs(@builtin(vertex_index) n:u32,
 @location(0) dst:vec4<i32>, @location(1) src:vec4<u32>, @location(2) color:vec4<u32>,
 @location(3) kind:vec4<u32>, @location(4) clip:vec4<i32>)->V{
 let corners=array<vec2<f32>,6>(vec2(0.,0.),vec2(1.,0.),vec2(0.,1.),vec2(0.,1.),vec2(1.,0.),vec2(1.,1.));
 let xy=vec2<f32>(dst.xy)+corners[n]*vec2<f32>(dst.zw);
 var out:V;out.pos=vec4(xy.x/f32(globals.surface.x)*2.-1.,1.-xy.y/f32(globals.surface.y)*2.,0.,1.);
 out.dst=dst;out.src=src;out.color=color;out.kind=kind;out.clip=clip;return out;
}
@fragment fn fs(p:V)->@location(0) vec4<f32>{
 let pos=vec2<i32>(p.pos.xy);
 if any(pos<p.clip.xy) || any(pos>=p.clip.xy+p.clip.zw) {discard;}
 var c=p.color; var coverage=255u;
 if p.kind.x!=0u {
  let xy=vec2<u32>(pos-p.dst.xy);
  let src=p.src.xy+xy*p.src.zw/vec2<u32>(p.dst.zw);
  let v=textureLoad(atlas,vec2<i32>(src),0);
  if p.kind.x==1u {coverage=v.x;} else {c=v;}
 }
 let a=c.a*coverage/255u;
 return vec4(vec3<f32>(c.rgb)/255.,f32(a)/255.);
}
