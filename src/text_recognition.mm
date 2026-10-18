#include "text_recognition.h"

#include "a11y_log.h"

#include <QtCore/QCoreApplication>
#include <QtCore/QList>
#include <QtCore/QMetaObject>
#include <QtCore/QPointer>
#include <QtCore/QString>
#include <QtGui/QImage>

#import <Vision/Vision.h>

#include <algorithm>

namespace line_a11y {

QStringList recognizeTextLines(const QImage &image)
{
    if (image.isNull())
        return {};
    // toCGImage() only handles RGB(A) formats.
    CGImageRef cgImage = image.convertToFormat(QImage::Format_RGB32).toCGImage();
    if (!cgImage)
        return {};

    struct Line {
        CGRect box; // normalised, origin bottom-left
        QString text;
    };
    QList<Line> lines;
    @autoreleasepool {
        VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] init];
        request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
        request.usesLanguageCorrection = NO; // times and dates, not prose
        request.recognitionLanguages = @[ @"th-TH", @"en-US" ];
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cgImage options:@{}];
        NSError *error = nil;
        if (![handler performRequests:@[ request ] error:&error]) {
            static bool logged = false;
            if (!logged) {
                logged = true;
                a11yLog("[ocr] text recognition failed: %s", error.localizedDescription.UTF8String ?: "?");
            }
        }
        for (VNRecognizedTextObservation *observation in request.results) {
            VNRecognizedText *best = [observation topCandidates:1].firstObject;
            if (best.string.length)
                lines.append({ observation.boundingBox, QString::fromNSString(best.string).trimmed() });
        }
    }
    CGImageRelease(cgImage);

    // Top to bottom (Vision's origin is bottom-left), then group lines whose vertical centre lies
    // within the current line's extent and order each group left to right.
    std::sort(lines.begin(), lines.end(), [](const Line &a, const Line &b) { return CGRectGetMaxY(a.box) > CGRectGetMaxY(b.box); });
    QStringList texts;
    for (qsizetype start = 0; start < lines.size();) {
        const double bottom = CGRectGetMinY(lines[start].box);
        qsizetype end = start + 1;
        while (end < lines.size() && CGRectGetMidY(lines[end].box) >= bottom)
            ++end;
        QList<Line> group = lines.mid(start, end - start);
        std::stable_sort(group.begin(), group.end(), [](const Line &a, const Line &b) { return a.box.origin.x < b.box.origin.x; });
        for (const Line &line : std::as_const(group)) {
            if (!line.text.isEmpty())
                texts << line.text;
        }
        start = end;
    }
    return texts;
}

void recognizeTextLinesAsync(const QImage &image, QObject *context, std::function<void(const QStringList &)> done)
{
    static dispatch_queue_t queue = dispatch_queue_create(
        "line_a11y.text_recognition", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    QPointer<QObject> guard(context);
    const QImage copy = image; // implicitly shared; only read on the queue
    auto *callback = new std::function<void(const QStringList &)>(std::move(done));
    dispatch_async(queue, ^{
        const QStringList lines = recognizeTextLines(copy);
        QMetaObject::invokeMethod(QCoreApplication::instance(), [guard, callback, lines] {
            if (guard)
                (*callback)(lines);
            delete callback;
        }, Qt::QueuedConnection);
    });
}

} // namespace line_a11y
