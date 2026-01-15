module.exports = async ({ github, context, header, body }) => {
  // Validate required inputs
  if (!context.payload.number) {
    throw new Error('context.payload.number is required but was not provided');
  }

  const comment = [header, body].join("\n");
  let commentFn = "createComment";

  try {
    const { data: comments } = await github.rest.issues.listComments({
      owner: context.repo.owner,
      repo: context.repo.repo,
      issue_number: context.payload.number,
    });

    // Find existing comment by header match only (bot-agnostic)
    const existingComment = comments.find(
      (c) => c.body && c.body.startsWith(header)
    );

    commentFn = existingComment ? "updateComment" : "createComment";

    await github.rest.issues[commentFn]({
      owner: context.repo.owner,
      repo: context.repo.repo,
      body: comment,
      ...(existingComment
        ? { comment_id: existingComment.id }
        : { issue_number: context.payload.number }),
    });
  } catch (error) {
    const status = error && error.status ? ` (status: ${error.status})` : "";
    const message = error && error.message ? error.message : String(error);
    throw new Error(
      `Error ${commentFn === "updateComment" ? "updating" : "creating"} GitHub issue comment${status}: ${message}`
    );
  }
};
