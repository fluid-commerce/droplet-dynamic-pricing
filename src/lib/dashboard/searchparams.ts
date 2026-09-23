/**
 * One reader for the `?dri=` / `?page=` pair every dropzone page takes.
 *
 * Next hands `searchParams` as `string | string[] | undefined`, because a
 * repeated parameter is an array. Each page picking the first element by hand
 * is four chances to forget.
 */
export type RawSearchParams = Record<string, string | string[] | undefined>;

export function firstValue(
  params: RawSearchParams,
  key: string,
): string | undefined {
  const value = params[key];
  return Array.isArray(value) ? value[0] : value;
}
