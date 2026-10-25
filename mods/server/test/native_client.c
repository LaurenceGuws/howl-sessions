#include "howl_server_client.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

_Static_assert(sizeof(hsc_ready) == 40, "ready C layout");
_Static_assert(sizeof(hsc_request_info) == 64, "native request C layout");
_Static_assert(offsetof(hsc_request_info, authority_client_id) == 56, "authority separate from terminal facts");
_Static_assert(sizeof(hvt_request) == 56, "VT request C layout");
_Static_assert(sizeof(hvt_interaction) == 16, "VT interaction C layout");
_Static_assert(sizeof(hsc_color) == 8, "color C layout");
_Static_assert(offsetof(hsc_ready, client_id) == 32, "ready offsets");

#define CHECK(x) do { if (!(x)) { fprintf(stderr,"C ABI proof failed line %d: %s\n",__LINE__,#x); failed=1; goto cleanup; } } while (0)
typedef struct { hsc_attachment *attachment; uint64_t revision; uint32_t result;
    _Atomic int entered, done, updates; } blocked;
static void *observe_blocked(void *arg) {
    blocked *p = arg;
    hsc_snapshot *snapshot = NULL;
    atomic_store_explicit(&p->entered,1,memory_order_release);
    for (;;) {
        p->result = hsc_observe(p->attachment, p->revision, 0, &snapshot);
        if (p->result != HSC_OK) break;
        hsc_metadata metadata={0};
        p->result=hsc_snapshot_metadata(snapshot,&metadata);
        hsc_snapshot_release(&snapshot);
        if (p->result != HSC_OK) break;
        if (metadata.delivery_revision <= p->revision) { p->result=HSC_PROTOCOL_ERROR; break; }
        p->revision=metadata.delivery_revision;
        if (atomic_fetch_add_explicit(&p->updates,1,memory_order_relaxed) >= 32) { p->result=HSC_INTERNAL; break; }
    }
    hsc_snapshot_release(&snapshot);
    atomic_store_explicit(&p->done,1,memory_order_release);
    return NULL;
}

int hsc_external_probe(const uint8_t *endpoint, size_t endpoint_len, uint64_t server_id) {
    int failed=0, joined=1;
    hsc_control *control=NULL;
    hsc_attachment *attachment=NULL, *observer=NULL;
    hsc_interrupt *interrupt=NULL;
    hsc_tree *tree=NULL;
    hsc_snapshot *snapshot=NULL, *graphics_snapshot=NULL;
    hsc_image *image=NULL;
    hsc_request_view *request_view=NULL, *observer_request=NULL;
    hsc_identity identity={0,0};
    hsc_ready ready={0};
    hsc_server_status status={0};
    hsc_metadata metadata={0};
    pthread_t thread;
    uint64_t session=0;
    CHECK(hsc_abi_version()==HSC_ABI_VERSION);
    CHECK(hsc_control_open(0, endpoint, endpoint_len, NULL, &control)==HSC_VERSION_MISMATCH);
    CHECK(control==NULL);
    CHECK(hsc_control_open(HSC_ABI_VERSION,NULL,1,NULL,&control)==HSC_INVALID_ARGUMENT);
    CHECK(hsc_interrupt_create(HSC_ABI_VERSION,&interrupt)==HSC_OK);
    CHECK(hsc_control_open(HSC_ABI_VERSION,endpoint,endpoint_len,NULL,&control)==HSC_OK);
    CHECK(hsc_control_status(control,&status)==HSC_OK);
    CHECK(status.server_id==server_id && status.instance_count==0);
    CHECK(hsc_session_create(control,(const uint8_t *)"bad name",8,&session)==HSC_INVALID_ARGUMENT && session==0);
    CHECK(hsc_session_create(control,(const uint8_t *)"abi",3,&session)==HSC_OK);
    uint64_t duplicate=0;
    CHECK(hsc_session_create(control,(const uint8_t *)"abi",3,&duplicate)==HSC_NAME_EXISTS && duplicate==0);
    const char command[]="printf '\\033]2;ABI title\\007\\033]1;\\007\\033]9;4;1;37\\007\\033[1;31mA\\314\\201\\033[0m\\033]8;;https://example.invalid/x\\033\\\\B\\033]8;;\\033\\\\'; IFS= read -r line; printf '\\033_Ga=T,f=32,s=1,v=1,i=7,q=2;AQIDBA==\\033\\\\'; IFS= read -r line; stty -echo -icanon; printf '\\033]52;c;?\\033\\\\'; dd bs=1 count=9 2>/dev/null | od -An -tx1; exec cat";
    hsc_launch launch={0};
    launch.session_id=session; launch.rows=2; launch.columns=12; launch.history_rows=4;
    launch.shell=(const uint8_t *)"/bin/sh"; launch.shell_len=7;
    launch.command=(const uint8_t *)command; launch.command_len=strlen(command);
    launch.reserved=1;
    CHECK(hsc_instance_create(control,&launch,&identity)==HSC_INVALID_ARGUMENT && identity.instance_id==0);
    launch.reserved=0;
    CHECK(hsc_instance_create(control,&launch,&identity)==HSC_OK);
    CHECK(identity.session_id==session && identity.instance_id!=0);
    CHECK(hsc_attachment_open(HSC_ABI_VERSION,endpoint,endpoint_len,server_id+1,session,identity.instance_id,interrupt,&attachment)==HSC_STALE_SERVER);
    CHECK(attachment==NULL);
    CHECK(hsc_attachment_open(HSC_ABI_VERSION,endpoint,endpoint_len,server_id,session,identity.instance_id,interrupt,&attachment)==HSC_OK);
    CHECK(hsc_attachment_identity(attachment,&ready)==HSC_OK);
    CHECK(ready.server_id==server_id && ready.session_id==session &&
          ready.instance_id==identity.instance_id && ready.client_id!=0);
    CHECK(hsc_control_status(control,&status)==HSC_OK && status.instance_count==1);
    CHECK(hsc_attachment_open(HSC_ABI_VERSION,endpoint,endpoint_len,server_id,session,identity.instance_id,NULL,&observer)==HSC_OK);
    hsc_ready observer_ready={0};
    CHECK(hsc_attachment_identity(observer,&observer_ready)==HSC_OK &&
          observer_ready.instance_id==ready.instance_id && observer_ready.client_id!=ready.client_id);
    CHECK(hsc_named_key(attachment,999,1,0)==HSC_INVALID_ARGUMENT);
    CHECK(hsc_text(attachment,NULL,1,0)==HSC_INVALID_ARGUMENT);
    const uint8_t invalid_utf8[]={0xff};
    CHECK(hsc_text(attachment,invalid_utf8,1,0)==HSC_INVALID_ARGUMENT);
    CHECK(hsc_unicode_key(attachment,0xd800,HSC_KEY_PRESS,0)==HSC_INVALID_ARGUMENT);
    CHECK(hsc_resize(attachment,0,12,1)==HSC_INVALID_ARGUMENT);
    CHECK(hsc_resize(attachment,2,12,0)==HSC_NOT_LEADER);
    CHECK(hsc_focus(attachment,HSC_FOCUS_IN)==HSC_OK);
    for (unsigned attempt=0; attempt<200; ++attempt) {
        hsc_snapshot_release(&snapshot);
        CHECK(hsc_observe(attachment,0,0,&snapshot)==HSC_OK);
        CHECK(hsc_snapshot_metadata(snapshot,&metadata)==HSC_OK);
        if (metadata.hyperlink_count && metadata.scalar_count>=3) break;
        struct timespec pause={.tv_sec=0,.tv_nsec=1000000};
        nanosleep(&pause,NULL);
    }
    CHECK(metadata.rows==2 && metadata.columns==12 && metadata.hyperlink_count==1);
    const uint32_t *scalars=NULL;
    size_t scalar_len=0, written=0;
    CHECK(hsc_snapshot_scalars(snapshot,&scalars,&scalar_len)==HSC_OK);
    CHECK(scalar_len>=3 && scalars[0]=='A' && scalars[1]==0x301 && scalars[2]=='B');
    hsc_row row={0};
    CHECK(hsc_snapshot_row(snapshot,0,&row)==HSC_OK && row.cell_count>=2);
    CHECK(hsc_snapshot_row(snapshot,metadata.row_count,&row)==HSC_INVALID_ARGUMENT);
    struct { hsc_cell cell; uint64_t guard; } bounded_cell;
    memset(&bounded_cell,0,sizeof(bounded_cell)); bounded_cell.guard=0xaabbccdd11223344ULL;
    CHECK(hsc_snapshot_cells(snapshot,0,&bounded_cell.cell,1,&written)==HSC_OK);
    CHECK(written==1 && bounded_cell.guard==0xaabbccdd11223344ULL);
    CHECK(bounded_cell.cell.scalar_count==2 && bounded_cell.cell.style & 1);
    CHECK(bounded_cell.cell.foreground.kind==1 && bounded_cell.cell.foreground.value==1);
    CHECK(hsc_snapshot_cells(snapshot,0,NULL,1,&written)==HSC_INVALID_ARGUMENT && written==0);
    hsc_hyperlink link={0};
    CHECK(hsc_snapshot_hyperlink(snapshot,0,&link)==HSC_OK);
    CHECK(link.uri_len==strlen("https://example.invalid/x") &&
          memcmp(link.uri,"https://example.invalid/x",link.uri_len)==0);
    hsc_presentation presentation={0};
    CHECK(hsc_snapshot_presentation(snapshot,&presentation)==HSC_OK);
    CHECK(presentation.foreground.a==255 && presentation.palette[1].a==255);
    hsc_properties properties={0};
    CHECK(hsc_snapshot_properties(snapshot,&properties)==HSC_OK);
    CHECK((properties.present & 3)==3 && properties.title.length==9 &&
          memcmp(properties.title.bytes,"ABI title",9)==0 && properties.icon.length==0);
    CHECK(!(properties.present & 4) && properties.progress_kind==1 && properties.progress_value==37);
    hsc_geometry geometry={2,12,8,16};
    CHECK(hsc_resize_geometry(attachment,&geometry,1)==HSC_OK);
    CHECK(hsc_resize_geometry(observer,&geometry,0)==HSC_NOT_LEADER);
    hsc_mouse mouse={0}; mouse.kind=HSC_MOUSE_MOVE; mouse.button=HSC_MOUSE_NONE;
    mouse.has_pixels=1; mouse.pixel_x=2; mouse.pixel_y=3;
    CHECK(hsc_mouse_input(attachment,&mouse)==HSC_OK);
    CHECK(hsc_text(attachment,(const uint8_t *)"go",2,1)==HSC_OK);
    CHECK(hsc_named_key(attachment,HSC_KEY_ENTER,HSC_KEY_PRESS,0)==HSC_OK);
    hsc_graphics graphics={0};
    for (unsigned attempt=0; attempt<200; ++attempt) {
        hsc_snapshot_release(&graphics_snapshot);
        CHECK(hsc_observe(attachment,0,0,&graphics_snapshot)==HSC_OK);
        CHECK(hsc_snapshot_metadata(graphics_snapshot,&metadata)==HSC_OK);
        CHECK(hsc_snapshot_graphics(graphics_snapshot,&graphics)==HSC_OK);
        if (graphics.image_count==1 && graphics.placement_count==1) break;
        struct timespec pause={.tv_sec=0,.tv_nsec=1000000}; nanosleep(&pause,NULL);
    }
    CHECK(graphics.image_count==1 && graphics.placement_count==1 &&
          graphics.cell_pixel_width==8 && graphics.cell_pixel_height==16);
    CHECK(metadata.flags & 64);
    hsc_image_identity image_identity={0};
    hsc_placement placement={0};
    CHECK(hsc_snapshot_image(graphics_snapshot,0,&image_identity)==HSC_OK);
    CHECK(image_identity.image_id!=0 && image_identity.width==1 && image_identity.height==1);
    CHECK(hsc_snapshot_placement(graphics_snapshot,0,&placement)==HSC_OK &&
          placement.image_id==image_identity.image_id && placement.generation==image_identity.generation);
    CHECK(hsc_snapshot_image(graphics_snapshot,1,&image_identity)==HSC_INVALID_ARGUMENT);
    CHECK(hsc_image_fetch(attachment,image_identity.image_id,image_identity.generation,&image)==HSC_OK);
    const uint8_t *pixels=NULL; size_t pixel_length=0;
    CHECK(hsc_image_data(image,&image_identity,&pixels,&pixel_length)==HSC_OK &&
          pixel_length==4 && pixels[0]==1 && pixels[1]==2 && pixels[2]==3 && pixels[3]==4);
    hsc_snapshot_release(&graphics_snapshot);
    CHECK(pixels[3]==4);
    hvt_interaction interaction={0};
    CHECK(hsc_interaction(attachment,&interaction)==HSC_OK);
    hsc_request_info request_info={0}, observer_info={0};
    CHECK(hsc_request_observe(observer,&observer_request)==HSC_OK);
    CHECK(hsc_request_view_info(observer_request,&observer_info)==HSC_OK && observer_info.authority_client_id==0);
    hsc_request_view_release(&observer_request);
    CHECK(hsc_request_acquire(attachment)==HSC_OK);
    CHECK(hsc_named_key(attachment,HSC_KEY_ENTER,HSC_KEY_PRESS,0)==HSC_OK);
    for (unsigned attempt=0; attempt<200; ++attempt) {
        hsc_request_view_release(&request_view);
        CHECK(hsc_request_observe(attachment,&request_view)==HSC_OK);
        CHECK(hsc_request_view_info(request_view,&request_info)==HSC_OK);
        if (request_info.request.kind==HVT_REQUEST_CLIPBOARD) break;
        struct timespec pause={.tv_sec=0,.tv_nsec=1000000}; nanosleep(&pause,NULL);
    }
    CHECK(request_info.request.kind==HVT_REQUEST_CLIPBOARD && request_info.request.reply_required==1);
    CHECK(request_info.request.data.clipboard.protocol==HVT_CLIPBOARD_OSC52 &&
          request_info.request.data.clipboard.operation==HVT_CLIPBOARD_QUERY &&
          request_info.request.data.clipboard.selection_len==1);
    CHECK(request_info.authority_client_id==ready.client_id);
    /* Invalid lengths must be checked before dereferencing even this null body. */
    CHECK(hsc_reply_clipboard(attachment,request_info.request.occurrence_id,NULL,HSC_MAX_CLIPBOARD_REPLY_BYTES+1)==HSC_RESOURCE_LIMIT);
    CHECK(hsc_reply_pointer_shape(attachment,request_info.request.occurrence_id,NULL,HSC_MAX_POINTER_REPLY_BYTES+1)==HSC_RESOURCE_LIMIT);
    CHECK(hsc_reply_container_icon_title(attachment,request_info.request.occurrence_id,NULL,HSC_MAX_ICON_TITLE_REPLY_BYTES+1)==HSC_RESOURCE_LIMIT);
    CHECK(hsc_request_consume(observer,request_info.request.occurrence_id)==HSC_NOT_AUTHORITY);
    CHECK(hsc_request_observe(observer,&observer_request)==HSC_OK);
    CHECK(hsc_request_view_info(observer_request,&observer_info)==HSC_OK && observer_info.authority_client_id==ready.client_id);
    const uint8_t *request_payload=NULL; size_t request_length=0;
    CHECK(hsc_request_view_payload(observer_request,&request_payload,&request_length)==HSC_OK);
    CHECK(request_length==3 && memcmp(request_payload,"c;?",3)==0);
    CHECK(hsc_reply_color_preference(attachment,request_info.request.occurrence_id,255)==HSC_INVALID_ARGUMENT);
    CHECK(hsc_reply_clipboard(observer,request_info.request.occurrence_id,NULL,0)==HSC_NOT_AUTHORITY);
    CHECK(hsc_reply_clipboard(attachment,request_info.request.occurrence_id+1,NULL,0)==HSC_REJECTED);
    CHECK(hsc_reply_clipboard(attachment,request_info.request.occurrence_id,NULL,0)==HSC_OK);
    hsc_attachment_release(&observer);
    CHECK(hsc_request_view_info(observer_request,&observer_info)==HSC_OK && observer_info.request.occurrence_id==request_info.request.occurrence_id);
    CHECK(request_length==3 && request_payload[0]=='c' && request_payload[1]==';' && request_payload[2]=='?');
    CHECK(hsc_request_observe(attachment,&request_view)==HSC_INVALID_ARGUMENT);
    hsc_request_view_release(&request_view);
    CHECK(hsc_request_observe(attachment,&request_view)==HSC_OK);
    CHECK(hsc_request_view_info(request_view,&request_info)==HSC_OK && request_info.request.kind==HVT_REQUEST_NONE);
    CHECK(hsc_control_tree(control,0,&tree)==HSC_OK);
    hsc_session session_view={0}; hsc_instance instance_view={0};
    CHECK(hsc_tree_session(tree,0,&session_view)==HSC_OK);
    CHECK(session_view.id==session && session_view.name_len==3 && memcmp(session_view.name,"abi",3)==0);
    CHECK(hsc_tree_instance(tree,0,0,&instance_view)==HSC_OK && instance_view.id==identity.instance_id);
    CHECK(hsc_tree_instance(tree,0,1,&instance_view)==HSC_INVALID_ARGUMENT);
    /* Drain any late burst publication, then park at its latest delivered revision. */
    blocked probe={attachment,metadata.delivery_revision,0xffffffffu,ATOMIC_VAR_INIT(0),ATOMIC_VAR_INIT(0),ATOMIC_VAR_INIT(0)};
    CHECK(pthread_create(&thread,NULL,observe_blocked,&probe)==0); joined=0;
    for (unsigned attempt=0; attempt<200 && !atomic_load_explicit(&probe.entered,memory_order_acquire); ++attempt) {
        struct timespec pause={.tv_sec=0,.tv_nsec=1000000}; nanosleep(&pause,NULL);
    }
    CHECK(atomic_load_explicit(&probe.entered,memory_order_acquire));
    struct timespec parked={.tv_sec=0,.tv_nsec=20000000}; nanosleep(&parked,NULL);
    CHECK(!atomic_load_explicit(&probe.done,memory_order_acquire));
    CHECK(hsc_interrupt_cancel(interrupt)==HSC_OK);
    CHECK(pthread_join(thread,NULL)==0); joined=1;
    CHECK(probe.result==HSC_CANCELLED);
    CHECK(hsc_focus(attachment,HSC_FOCUS_OUT)==HSC_RETIRED);
    hsc_attachment_release(&attachment);
    CHECK(attachment==NULL);
    hsc_attachment_release(&attachment);
    /* Both borrowed terminal and catalog bytes survive connection teardown. */
    CHECK(hsc_snapshot_metadata(snapshot,&metadata)==HSC_OK);
    CHECK(scalars[0]=='A' && link.uri[0]=='h' && properties.title.bytes[0]=='A' && pixels[3]==4);
    CHECK(hsc_control_status(control,&status)==HSC_OK && status.instance_count==1);
    CHECK(hsc_instance_close(control,identity)==HSC_OK); identity.instance_id=0;
    CHECK(hsc_session_close(control,session)==HSC_OK); session=0;
    hsc_control_release(&control);
    CHECK(hsc_tree_session(tree,0,&session_view)==HSC_OK && session_view.name[0]=='a');
cleanup:
    if (!joined) { hsc_interrupt_cancel(interrupt); pthread_join(thread,NULL); }
    hsc_request_view_release(&observer_request);
    hsc_request_view_release(&request_view);
    hsc_image_release(&image);
    hsc_snapshot_release(&graphics_snapshot);
    hsc_snapshot_release(&snapshot);
    hsc_tree_release(&tree);
    hsc_attachment_release(&observer);
    hsc_attachment_release(&attachment);
    if (control && identity.instance_id) hsc_instance_close(control,identity);
    if (control && session) hsc_session_close(control,session);
    hsc_control_release(&control);
    hsc_interrupt_release(&interrupt);
    if (!failed) fprintf(stdout,"external C client: identity, CRUD, independent attachments, rich properties/images, bounded cells, parked cancellation and detach passed\n");
    return failed;
}
