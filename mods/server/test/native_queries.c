#include "howl_server_client.h"
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/* This peer creates every client/result/cache owner through installed C symbols.
 * Server pumping, endpoint, shell and deadlines belong solely to the proof. */
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"query C proof line %d: %s\n",__LINE__,#x); failed=__LINE__; goto cleanup; } } while (0)
_Static_assert(sizeof(hsc_selection_span)==8 && _Alignof(hsc_selection_span)==2,"selection span");
_Static_assert(offsetof(hsc_selection_span,first)==0 && offsetof(hsc_selection_span,last)==2,"span columns");
_Static_assert(offsetof(hsc_selection_span,found)==4 && offsetof(hsc_selection_span,reserved)==5,"span tail");
_Static_assert(sizeof(hsc_changes)==16 && _Alignof(hsc_changes)==8,"change envelope");
_Static_assert(offsetof(hsc_changes,base_revision)==0 && offsetof(hsc_changes,row_count)==8,"change identity");
_Static_assert(offsetof(hsc_changes,row_shift)==12 && offsetof(hsc_changes,flags)==14 && offsetof(hsc_changes,reserved)==15,"change tail");
_Static_assert(HSC_SELECTION_VALID==1 && HSC_SELECTION_CONTEXT_CHANGED==2 && HSC_SELECTION_EVICTED==3,"validity tags");
_Static_assert(HSC_CHANGED_ROWS_PRESENT==1 && HSC_CHANGE_BASE_PRESENT==2 && HSC_ROW_SHIFT_PRESENT==4,"change flags");
_Static_assert(HSC_MAX_SEARCH_QUERY_BYTES==4096 && HSC_MAX_SELECTION_BYTES==1048576,"native ceilings");
extern int hsc_query_cpp(void);
static uint64_t now_ns(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC,&t)) return 0;
    return (uint64_t)t.tv_sec*UINT64_C(1000000000)+(uint64_t)t.tv_nsec;
}
static int await_snapshot(hsc_attachment *attachment, hsc_cache *cache, int tall, hsc_snapshot **out) {
    const uint64_t deadline=now_ns()+UINT64_C(5000000000);
    for (unsigned n=0;n<500 && now_ns()<deadline;++n) {
        hsc_snapshot *next=NULL;
        if (hsc_observe_cached(attachment,cache,0,0,&next)!=HSC_OK) return 1;
        hvt_search_match match={0}, end={0};
        uint32_t status=hsc_snapshot_search_row(next,(const uint8_t *)(tall ? "Hi" : "READY"),
            tall ? 2 : 5,tall ? 0 : 3,0,0,&match);
        if (status==HSC_OK && match.found) {
            if (!tall || (hsc_snapshot_search_row(next,(const uint8_t *)"e",1,1,0,0,&end)==HSC_OK &&
                end.found && end.start_column==4)) { *out=next; return 0; }
        }
        hsc_snapshot_release(&next);
    }
    return 1;
}
int hsc_queries_probe(const uint8_t *endpoint, size_t length, uint64_t server_id) {
    int failed=0;
    hsc_control *control=NULL;
    hsc_attachment *attachment=NULL,*other=NULL;
    hsc_cache *cache=NULL;
    hsc_snapshot *packed=NULL,*first=NULL,*second=NULL,*resized=NULL,*tall=NULL,*attempt=NULL;
    hsc_text_view *text=NULL,*tall_text=NULL,*rejected=NULL;
    hsc_identity identity={0};
    uint64_t session=0;
    const uint8_t *text_bytes=NULL,*scalar_uri=NULL;
    size_t text_length=0;
    hsc_server_status status={0};
    hsc_metadata initial={0},delta={0},current={0};
    hsc_changes change={0};
    const char shell[]="/bin/sh";
    const char command[]=
        "stty -echo; printf '\\033[H\\033[2Jalpha e\\314\\201 \\347\\225\\214 omega\\r\\n"
        "\\033]8;;https://example.invalid/native-query\\007\\347\\225\\214\\033]8;;\\007 LINK\\r\\n"
        "\\033[8msecret\\033[0m public\\r\\nREADY'; "
        "while IFS= read -r line; do case \"$line\" in "
        "changed) printf '\\033[5;1Hchanged';; "
        "tall) printf '\\033[2J\\033[H\\033]66;s=2:w=2:n=1:d=2:v=1:h=2;Hi\\007abcde';; "
        "*) printf '\\r\\n%s' \"$line\";; esac; done";
    hsc_launch launch={0};
    alarm(20);
    CHECK(now_ns()!=0 && hsc_query_cpp()==0);
    CHECK(hsc_control_open(HSC_ABI_VERSION,endpoint,length,NULL,&control)==HSC_OK);
    CHECK(hsc_control_status(control,&status)==HSC_OK && status.server_id==server_id);
    CHECK(hsc_session_create(control,(const uint8_t *)"queries",7,&session)==HSC_OK);
    launch.session_id=session; launch.rows=6; launch.columns=32; launch.history_rows=16;
    launch.shell=(const uint8_t *)shell; launch.shell_len=sizeof(shell)-1;
    launch.command=(const uint8_t *)command; launch.command_len=sizeof(command)-1;
    CHECK(hsc_instance_create(control,&launch,&identity)==HSC_OK);
    CHECK(hsc_attachment_open(HSC_ABI_VERSION,endpoint,length,server_id,session,identity.instance_id,NULL,&attachment)==HSC_OK);
    hsc_geometry geometry={6,32,10,20};
    CHECK(hsc_resize_geometry(attachment,&geometry,1)==HSC_OK);
    CHECK(hsc_cache_create(99,attachment,&cache)==HSC_VERSION_MISMATCH && !cache);
    CHECK(hsc_cache_create(HSC_ABI_VERSION,attachment,NULL)==HSC_INVALID_ARGUMENT);
    CHECK(hsc_cache_create(HSC_ABI_VERSION,attachment,&cache)==HSC_OK && cache);
    hsc_cache *saved_cache=cache;
    CHECK(hsc_cache_create(HSC_ABI_VERSION,attachment,&cache)==HSC_INVALID_ARGUMENT && cache==saved_cache);
    CHECK(hsc_observe_cached(attachment,cache,0,0,NULL)==HSC_INVALID_ARGUMENT);
    CHECK(hsc_attachment_open(HSC_ABI_VERSION,endpoint,length,server_id,session,identity.instance_id,NULL,&other)==HSC_OK);
    CHECK(hsc_observe_cached(other,cache,0,0,&attempt)==HSC_INVALID_ARGUMENT && !attempt);
    hvt_interaction interaction={0};
    CHECK(hsc_interaction(other,&interaction)==HSC_OK);
    hsc_attachment_release(&other);
    CHECK(hsc_observe(attachment,0,0,&packed)==HSC_OK);
    CHECK(hsc_snapshot_changes(packed,&change)==HSC_OK && change.flags==0);
    uint8_t absent=77; size_t required=99;
    CHECK(hsc_snapshot_changed_rows(packed,&absent,SIZE_MAX,&required)==HSC_OK && required==0 && absent==77);
    CHECK(await_snapshot(attachment,cache,0,&first)==0);
    CHECK(hsc_snapshot_metadata(first,&initial)==HSC_OK && initial.rows==6 && initial.columns==32);
    CHECK(hsc_observe_cached(attachment,cache,initial.delivery_revision+123,0,&attempt)==HSC_INVALID_ARGUMENT && !attempt);
    CHECK(hsc_observe_cached(attachment,cache,initial.delivery_revision,1,&attempt)==HSC_INVALID_ARGUMENT && !attempt);
    CHECK(hsc_interaction(attachment,&interaction)==HSC_OK);
    hvt_search_match match={0};
    CHECK(hsc_snapshot_search_row(first,(const uint8_t *)"e\xcc\x81",3,0,0,0,&match)==HSC_OK &&
        match.found && match.start_column==6 && match.end_column==6 && match.complete && match.scanned_snapshots==1);
    CHECK(match.cut_revision==initial.terminal_revision);
    CHECK(hsc_snapshot_search_row(first,(const uint8_t *)"\xe7\x95\x8c",3,0,31,1,&match)==HSC_OK &&
        match.found && match.start_column==8 && match.end_column==9);
    CHECK(hsc_snapshot_search(first,(const uint8_t *)"secret",6,0,0,&match)==HSC_OK && !match.found && match.complete);
    memset(&match,0xa5,sizeof(match));
    CHECK(hsc_snapshot_search(first,(const uint8_t *)"x",1,0,2,&match)==HSC_INVALID_ARGUMENT && !match.cut_revision && !match.found);
    CHECK(hsc_snapshot_search(first,NULL,1,0,0,&match)==HSC_INVALID_ARGUMENT);
    CHECK(hsc_snapshot_search(first,(const uint8_t *)"x",HSC_MAX_SEARCH_QUERY_BYTES+1u,0,0,&match)==HSC_RESOURCE_LIMIT);
    CHECK(hsc_snapshot_search_row(first,(const uint8_t *)"x",1,6,0,0,&match)==HSC_INVALID_ARGUMENT);
    hvt_selection_range range={0};
    CHECK(hsc_snapshot_expand_selection(first,HVT_SELECTION_WORD,0,1,&range)==HSC_OK &&
        range.found && range.start_column==0 && range.end_column==4);
    uint32_t validity=0;
    CHECK(hsc_snapshot_selection_validity(first,&range,&validity)==HSC_OK && validity==HSC_SELECTION_VALID);
    hsc_selection_span span={0};
    CHECK(hsc_snapshot_selection_span(first,&range,0,&span)==HSC_OK && span.found && span.first==0 && span.last==4);
    hvt_selection_range bad=range; bad._reserved[1]=1;
    CHECK(hsc_selection_extract(attachment,&bad,&rejected)==HSC_INVALID_ARGUMENT && !rejected);
    CHECK(hsc_selection_extract(attachment,&range,NULL)==HSC_INVALID_ARGUMENT);
    CHECK(hsc_selection_extract(attachment,&range,&text)==HSC_OK && text);
    CHECK(hsc_text_view_data(text,&text_bytes,&text_length)==HSC_OK && text_length==5 && memcmp(text_bytes,"alpha",5)==0);
    hvt_row_shape shapes[7];
    memset(shapes,0xa5,sizeof(shapes));
    CHECK(hsc_snapshot_row_shapes(first,shapes,1,&required)==HSC_BUFFER_TOO_SMALL && required==6 && shapes[0].wrapped==0xa5);
    CHECK(hsc_snapshot_row_shapes(first,shapes,SIZE_MAX,&required)==HSC_OK && required==6 && shapes[6].wrapped==0xa5);
    CHECK(shapes[0].content_end_exclusive==16 && shapes[0]._reserved==0);
    uint8_t uri[128]; memset(uri,0xa5,sizeof(uri));
    CHECK(hsc_snapshot_copy_hyperlink(first,1,1,uri,1,&required)==HSC_BUFFER_TOO_SMALL && uri[0]==0xa5);
    const char expected_uri[]="https://example.invalid/native-query";
    CHECK(required==sizeof(expected_uri)-1);
    CHECK(hsc_snapshot_copy_hyperlink(first,1,1,uri,sizeof(uri),&required)==HSC_OK && memcmp(uri,expected_uri,required)==0 && uri[required]==0xa5);
    CHECK(hsc_snapshot_copy_hyperlink(first,0,0,NULL,0,&required)==HSC_OK && required==0);
    CHECK(hsc_snapshot_copy_hyperlink(first,0,0,uri,HSC_MAX_SELECTION_BYTES+1u,&required)==HSC_RESOURCE_LIMIT && required==0);
    /* Also retain an existing view-owned URI borrow through cache advance. */
    hsc_hyperlink link={0}; CHECK(hsc_snapshot_hyperlink(first,0,&link)==HSC_OK);
    scalar_uri=link.uri;
    CHECK(hsc_text(attachment,(const uint8_t *)"changed\n",8,0)==HSC_OK);
    CHECK(hsc_observe_cached(attachment,cache,initial.delivery_revision,0,&second)==HSC_OK && second);
    CHECK(hsc_snapshot_metadata(second,&delta)==HSC_OK && delta.delivery_revision>initial.delivery_revision);
    CHECK(hsc_snapshot_search(second,(const uint8_t *)"changed",7,0,0,&match)==HSC_OK && match.found);
    CHECK(hsc_snapshot_changes(second,&change)==HSC_OK &&
        (change.flags&(HSC_CHANGED_ROWS_PRESENT|HSC_CHANGE_BASE_PRESENT))==(HSC_CHANGED_ROWS_PRESENT|HSC_CHANGE_BASE_PRESENT) &&
        change.base_revision==initial.delivery_revision && change.row_count==6 && !change.reserved);
    uint8_t mask[7]; memset(mask,77,sizeof(mask));
    CHECK(hsc_snapshot_changed_rows(second,mask,1,&required)==HSC_BUFFER_TOO_SMALL && required==6 && mask[0]==77);
    CHECK(hsc_snapshot_changed_rows(second,mask,SIZE_MAX,&required)==HSC_OK && required==6 && mask[6]==77);
    CHECK(mask[4]==1);
    for (size_t n=0;n<required;++n) CHECK(mask[n]<=1);
    CHECK(hsc_snapshot_search(first,(const uint8_t *)"changed",7,0,0,&match)==HSC_OK && !match.found);
    geometry.columns=31;
    CHECK(hsc_resize_geometry(attachment,&geometry,1)==HSC_OK);
    CHECK(hsc_observe_cached(attachment,cache,0,0,&resized)==HSC_OK);
    CHECK(hsc_snapshot_metadata(resized,&current)==HSC_OK && current.columns==31);
    CHECK(hsc_snapshot_selection_validity(resized,&range,&validity)==HSC_OK && validity==HSC_SELECTION_CONTEXT_CHANGED);
    CHECK(hsc_selection_extract(attachment,&range,&rejected)==HSC_REJECTED && !rejected);
    CHECK(hsc_interaction(attachment,&interaction)==HSC_OK);
    /* Real transported tall occupancy: selection must terminate in both directions. */
    geometry.rows=2; geometry.columns=8;
    CHECK(hsc_resize_geometry(attachment,&geometry,1)==HSC_OK);
    CHECK(hsc_text(attachment,(const uint8_t *)"tall\n",5,0)==HSC_OK);
    CHECK(await_snapshot(attachment,cache,1,&tall)==0);
    CHECK(hsc_snapshot_expand_selection(tall,HVT_SELECTION_WORD,1,4,&bad)==HSC_OK &&
        bad.found && bad.start_column==0 && bad.end_column==4 && bad.end_row==bad.start_row+1);
    CHECK(hsc_selection_extract(attachment,&bad,&tall_text)==HSC_OK);
    const uint8_t *tall_bytes=NULL; size_t tall_length=0;
    CHECK(hsc_text_view_data(tall_text,&tall_bytes,&tall_length)==HSC_OK && tall_length==7 && memcmp(tall_bytes,"Hiabcde",7)==0);
    hsc_cache_release(&cache); CHECK(!cache);
    hsc_attachment_release(&attachment); CHECK(!attachment);
    CHECK(hsc_instance_close(control,identity)==HSC_OK); identity.instance_id=0;
    CHECK(hsc_session_close(control,session)==HSC_OK); session=0;
    hsc_control_release(&control);
    /* Snapshots, damage, URI borrows and extraction bytes own independent storage. */
    CHECK(hsc_snapshot_metadata(first,&current)==HSC_OK && current.columns==32);
    CHECK(hsc_snapshot_search(first,(const uint8_t *)"alpha",5,0,0,&match)==HSC_OK && match.found);
    CHECK(memcmp(scalar_uri,expected_uri,sizeof(expected_uri)-1)==0);
    CHECK(hsc_snapshot_changes(second,&change)==HSC_OK && change.base_revision==initial.delivery_revision);
    CHECK(hsc_snapshot_changed_rows(second,mask,sizeof(mask),&required)==HSC_OK && mask[4]==1);
    CHECK(memcmp(text_bytes,"alpha",5)==0 && memcmp(tall_bytes,"Hiabcde",7)==0);
cleanup:
    hsc_text_view_release(&rejected);
    hsc_text_view_release(&tall_text);
    hsc_text_view_release(&text);
    hsc_snapshot_release(&attempt); hsc_snapshot_release(&tall);
    hsc_snapshot_release(&resized); hsc_snapshot_release(&second);
    hsc_snapshot_release(&first); hsc_snapshot_release(&packed);
    hsc_cache_release(&cache);
    hsc_attachment_release(&other); hsc_attachment_release(&attachment);
    if (control && identity.instance_id) hsc_instance_close(control,identity);
    if (control && session) hsc_session_close(control,session);
    hsc_control_release(&control);
    alarm(0);
    if (!failed) fprintf(stdout,"query C peer: bound cache, independent snapshots, Unicode/selection/URI, canonical text, tall wrap and lifetime passed\n");
    return failed;
}
