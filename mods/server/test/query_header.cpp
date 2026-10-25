#include "howl_server_client.h"
static_assert(sizeof(hsc_selection_span)==8 && alignof(hsc_selection_span)==2);
static_assert(offsetof(hsc_selection_span,first)==0 && offsetof(hsc_selection_span,last)==2);
static_assert(offsetof(hsc_selection_span,found)==4 && offsetof(hsc_selection_span,reserved)==5);
static_assert(sizeof(hsc_changes)==16 && alignof(hsc_changes)==8);
static_assert(offsetof(hsc_changes,base_revision)==0 && offsetof(hsc_changes,row_count)==8);
static_assert(offsetof(hsc_changes,row_shift)==12 && offsetof(hsc_changes,flags)==14 && offsetof(hsc_changes,reserved)==15);
static_assert(HSC_SELECTION_VALID==1 && HSC_SELECTION_CONTEXT_CHANGED==2 && HSC_SELECTION_EVICTED==3);
static_assert(HSC_CHANGED_ROWS_PRESENT==1 && HSC_CHANGE_BASE_PRESENT==2 && HSC_ROW_SHIFT_PRESENT==4);
static_assert(sizeof(hvt_search_match)==32 && sizeof(hvt_selection_range)==20 && sizeof(hvt_row_shape)==4);
extern "C" int hsc_query_cpp(void) { return hsc_abi_version()==HSC_ABI_VERSION ? 0 : 1; }
