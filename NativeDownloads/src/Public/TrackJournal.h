#pragma once
#import <Foundation/Foundation.h>
#import "Diagnostics.h"

// Полное состояние офлайн-загрузки каждого трека, собранное из настоящего трафика
// spotify.offline_esperanto.proto.Offline (разбор дескриптора — analysis/offline-esperanto-service.md).
// Журнал ничего не меняет: он только читает запросы/ответы, которые и так проходят
// через нативный транспорт, и сам отправляет исключительно read-only вызовы.

// Сырые байты одного вызова сервиса Offline. Декодирование уходит на очередь журнала.
void SAPJournalObserveCall(NSString *method, NSData *request, NSData *response, NSString *source);
// Запрос строки плейлиста: SPTOfflineManagerImplementation.stateForTrackWithURL:.
void SAPJournalNoteRowState(NSString *uri, NSUInteger state);
// Кнопка «Скачать» на плейлисте/альбоме: makeEntityAvailableOfflineWithURL:trackURLs: и её отмена.
void SAPJournalNoteEntityRequest(NSString *entity, NSArray *trackURLs);
void SAPJournalNoteEntityReset(NSString *entity);
// Статус значка загрузки, который получает строка списка
// (SPTFreeTierOfflineStatusUpdatingContentOperation.offlineSyncStatusForURL:):
// 0 нет, 1 ожидание, 2 идёт, 3 скачан, 4 ошибка.
void SAPJournalNoteUIStatus(NSString *uri, NSInteger status);
// Счётчики квоты нативного менеджера (current_tracks/music_limit и т.д.).
void SAPJournalNoteQuota(NSDictionary *quota);
// Optional audit for explicit Pixie actions and exact local before/after values.
// Never records secrets or infers a server response.
void SAPJournalNoteAction(NSString *name, NSDictionary *facts);
// Preserve the function ABI while avoiding construction of optional facts when
// diagnostics are disabled. Facts must not perform required application work.
#define SAP_JOURNAL_ACTION(name, ...) do { \
    if(SAPDiagnosticsEnabled())SAPJournalNoteAction((name),(__VA_ARGS__)); \
} while(0)
void SAPJournalFlushActions(void);
void SAPJournalNoteNativeError(NSString *uri, NSNumber *code, NSString *name);
void SAPJournalNoteNativeSuccess(NSString *uri, NSString *event);
NSDictionary *SAPJournalNativeErrorForURI(NSString *uri);

// Канал к ядру: отправляет read-only вызов Offline и возвращает lifetime (или nil).
// Для собственных вызовов ответ передаётся напрямую: он подтверждает ровно этот запрос.
// Пассивные обновления приложения не снимают запросы журнала с контроля.
// attempt выбирает канал: 0 — проверенный, дальше — следующие кандидаты. Нужен потому,
// что Cosmos-транспорт молча глотает часть ответов (analysis/native-download-v13.md).
typedef id (^SAPJournalCaller)(NSString *method, NSData *payload, BOOL stream, NSUInteger attempt,
                              void (^response)(NSData *));
void SAPJournalSetCaller(SAPJournalCaller caller);
// Блок, который просит нативный менеджер прислать свежий снимок квоты и флагов очереди.
void SAPJournalSetQuotaSampler(void (^sampler)(void));
void SAPJournalVerifyTrack(NSString *uri, void (^completion)(NSDictionary *track));
void SAPJournalNoteCallIssue(NSString *method, NSString *uri, NSString *channel, NSString *issue);
BOOL SAPJournalOnOwnQueue(void);

NSString *SAPJournalItemStateName(NSUInteger state);
void SAPJournalRefresh(NSString *reason);
NSDictionary *SAPJournalReport(void);
NSString *SAPJournalSummaryText(void);
NSString *SAPJournalSummaryForReport(NSDictionary *report);
NSURL *SAPJournalWriteReportSnapshot(NSDictionary *report);
NSURL *SAPJournalWriteTableSnapshot(NSDictionary *report);
NSURL *SAPJournalWriteReport(void);
NSURL *SAPJournalWriteTable(void);
void SAPJournalReset(void);
BOOL SAPJournalResetLogFiles(NSError **error);
#ifdef SAP_TESTING
void SAPJournalDrainForTesting(void);
void SAPJournalTimeoutsForTesting(void);
#endif
