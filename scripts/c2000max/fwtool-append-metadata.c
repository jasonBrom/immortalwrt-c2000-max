/* Minimal host-side OpenWrt fwtool metadata appender for recovery builds. */
#include <arpa/inet.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <zlib.h>

#define FWIMAGE_MAGIC 0x46577830U
#define FWIMAGE_INFO 1U
#define FWIMAGE_HEADER_SIZE 8U
#define FWIMAGE_TRAILER_SIZE 16U
#define METADATA_MAXLEN (30U * 1024U)

static int update_stream_crc(FILE *stream, uLong *crc)
{
	unsigned char buffer[64 * 1024];
	size_t length;

	while ((length = fread(buffer, 1, sizeof(buffer), stream)) != 0)
		*crc = crc32(*crc, buffer, (uInt)length);
	return ferror(stream) ? -1 : 0;
}

static int append_metadata(const char *image_name, const char *metadata_name)
{
	unsigned char header[FWIMAGE_HEADER_SIZE] = { 0 };
	unsigned char trailer[FWIMAGE_TRAILER_SIZE] = { 0 };
	unsigned char buffer[64 * 1024];
	FILE *image = NULL, *metadata = NULL;
	long metadata_size;
	uLong crc = crc32(0L, Z_NULL, 0);
	uint32_t value;
	size_t length;
	int result = 1;

	metadata = fopen(metadata_name, "rb");
	if (!metadata) {
		fprintf(stderr, "cannot open metadata: %s\n", strerror(errno));
		goto out;
	}
	if (fseek(metadata, 0, SEEK_END) != 0 ||
	    (metadata_size = ftell(metadata)) < 0 ||
	    (unsigned long)metadata_size > METADATA_MAXLEN ||
	    fseek(metadata, 0, SEEK_SET) != 0) {
		fprintf(stderr, "invalid metadata size\n");
		goto out;
	}

	image = fopen(image_name, "r+b");
	if (!image) {
		fprintf(stderr, "cannot open image: %s\n", strerror(errno));
		goto out;
	}
	if (update_stream_crc(image, &crc) != 0) {
		fprintf(stderr, "cannot read image\n");
		goto out;
	}

	crc = crc32(crc, header, sizeof(header));
	if (fwrite(header, 1, sizeof(header), image) != sizeof(header))
		goto write_error;

	while ((length = fread(buffer, 1, sizeof(buffer), metadata)) != 0) {
		crc = crc32(crc, buffer, (uInt)length);
		if (fwrite(buffer, 1, length, image) != length)
			goto write_error;
	}
	if (ferror(metadata)) {
		fprintf(stderr, "cannot read metadata\n");
		goto out;
	}

	value = htonl(FWIMAGE_MAGIC);
	memcpy(trailer, &value, sizeof(value));
	value = htonl((uint32_t)(crc ^ 0xffffffffU));
	memcpy(trailer + 4, &value, sizeof(value));
	trailer[8] = FWIMAGE_INFO;
	value = htonl((uint32_t)(FWIMAGE_HEADER_SIZE + metadata_size +
				 FWIMAGE_TRAILER_SIZE));
	memcpy(trailer + 12, &value, sizeof(value));
	if (fwrite(trailer, 1, sizeof(trailer), image) != sizeof(trailer))
		goto write_error;
	if (fflush(image) != 0 || fsync(fileno(image)) != 0)
		goto write_error;

	result = 0;
	goto out;

write_error:
	fprintf(stderr, "cannot append metadata: %s\n", strerror(errno));
out:
	if (image)
		fclose(image);
	if (metadata)
		fclose(metadata);
	return result;
}

int main(int argc, char **argv)
{
	if (argc != 3) {
		fprintf(stderr, "usage: %s IMAGE METADATA.json\n", argv[0]);
		return 2;
	}
	return append_metadata(argv[1], argv[2]);
}
